import Foundation

@MainActor final class WorkerClient {
    private static let supportedAPIVersion = 5
    private let baseURL = URL(string: "http://127.0.0.1:8767")!
    private let mutationGate = WorkerMutationGate()
    private var process: Process?
    private var logHandle: FileHandle?
    private var startupTask: Task<Void, Error>?

    func ensureRunning() async throws {
        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw WorkerError.unavailable("Tiro was closed during worker startup.") }
            try await self.reconcileWorker()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func reconcileWorker() async throws {
        switch await workerState() {
        case .compatible:
            return
        case .incompatible:
            try await stopIncompatibleWorker()
        case .unavailable:
            break
        }
        try await startAndWait()
    }

    private func startAndWait() async throws {
        if process?.isRunning != true {
            let embeddedWorker = AppPaths.embeddedWorkerExecutable
            let executableURL: URL
            let arguments: [String]
            if FileManager.default.isExecutableFile(atPath: embeddedWorker.path) {
                executableURL = embeddedWorker
                arguments = []
            } else {
                let pythonURL = AppPaths.projectRoot.appendingPathComponent(".venv/bin/python")
                guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
                    throw WorkerError.runtimeMissing(pythonURL.path)
                }
                executableURL = pythonURL
                arguments = [AppPaths.developmentWorkerEntryPoint.path]
            }

            try FileManager.default.createDirectory(
                at: AppPaths.workerLog.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: AppPaths.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: AppPaths.workerLog.path) {
                FileManager.default.createFile(atPath: AppPaths.workerLog.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: AppPaths.workerLog)
            try handle.seekToEnd()
            logHandle = handle

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = AppPaths.applicationSupportDirectory
            var environment = AppPaths.workerEnvironment()
            environment["TIRO_WORKER_TOKEN"] = try workerToken()
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            self.process = process
        }

        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await isHealthy() { return }
            if process?.isRunning == false { break }
        }
        throw WorkerError.unavailable(recentWorkerLog())
    }

    func transcribe(
        wavURL: URL,
        model: DictationModel,
        originBundleID: String? = nil,
        originName: String? = nil
    ) async throws -> TranscriptionResponse {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(model.key, forHTTPHeaderField: "X-Parakeet-Model")
        setOriginHeader(originBundleID, maximum: 255, field: "X-Tiro-Origin-Bundle-ID", on: &request)
        setOriginHeader(originName, maximum: 200, field: "X-Tiro-Origin-App-Name", on: &request)
        request.httpBody = try Data(contentsOf: wavURL)

        let data = try await send(request, operation: "Transcription")
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    func preload(model: DictationModel) async throws {
        try await ensureRunning()
        let availableModels = try await models()
        guard availableModels.contains(where: { $0.key == model.key && $0.installed }) else {
            throw WorkerError.server("Download \(model.name) before loading it.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/preload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue(model.key, forHTTPHeaderField: "X-Parakeet-Model")
        _ = try await send(request, operation: "Model preload")
    }

    func models() async throws -> [ManagedModel] {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/models"))
        request.setValue(try workerToken(), forHTTPHeaderField: "X-Tiro-Worker-Token")
        let data = try await send(request, operation: "Model list")
        return try JSONDecoder().decode(ModelsResponse.self, from: data).models
    }

    func downloadModel(key: String) async throws {
        try await serializedMutation {
            _ = try await authenticatedJSONPost(
                path: "api/models/download",
                body: ModelKeyRequest(key: key, model: key),
                operation: "Model download",
                timeout: 7_200
            )
        }
    }

    func deleteModel(key: String) async throws {
        try await serializedMutation {
            _ = try await authenticatedJSONPost(
                path: "api/models/delete",
                body: ModelKeyRequest(key: key, model: key),
                operation: "Model deletion"
            )
        }
    }

    func compareModels(
        historyID: String,
        modelKeys: [String],
        comparisonID: String
    ) async throws -> [ModelComparisonResult] {
        guard modelKeys.count >= 2 else {
            throw WorkerError.server("Choose at least two installed models.")
        }
        let data = try await authenticatedJSONPost(
            path: "api/models/compare",
            body: ModelComparisonRequest(
                history_id: historyID,
                model_keys: modelKeys,
                models: modelKeys,
                comparison_id: comparisonID
            ),
            operation: "Model comparison",
            timeout: 7_200
        )
        return try JSONDecoder().decode(ModelComparisonResponse.self, from: data).results
    }

    func cancelComparison(id: String) async {
        _ = try? await authenticatedJSONPost(
            path: "api/models/compare/cancel",
            body: ComparisonIDRequest(comparison_id: id),
            operation: "Model comparison cancellation"
        )
    }

    func searchHistory(query: String = "", limit: Int = 200) async throws -> [HistoryEntry] {
        try await ensureRunning()
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/history"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))
        ]
        guard let url = components.url else { throw WorkerError.invalidResponse }
        let data = try await send(URLRequest(url: url), operation: "History search")
        return try JSONDecoder().decode(HistoryResponse.self, from: data).entries
    }

    func historyAudio(id: String) async throws -> Data {
        try await ensureRunning()
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/history/audio"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { throw WorkerError.invalidResponse }
        return try await send(URLRequest(url: url), operation: "Audio replay")
    }

    func deleteHistoryEntry(id: String) async throws {
        try await authenticatedPost(
            path: "api/history/delete",
            body: HistoryIDRequest(id: id),
            operation: "History deletion"
        )
    }

    func correctHistoryEntry(id: String, correctedText: String) async throws {
        try await authenticatedPost(
            path: "api/history/correction",
            body: HistoryCorrectionRequest(id: id, corrected_text: correctedText),
            operation: "History correction"
        )
    }

    func setHistoryRetention(days: Int) async throws {
        guard [0, 7, 30, 90].contains(days) else {
            throw WorkerError.server("Retention must be Forever, 7, 30, or 90 days.")
        }
        try await authenticatedPost(
            path: "api/history/retention",
            body: RetentionRequest(days: days),
            operation: "History retention update"
        )
    }

    func vocabularyProfiles() async throws -> VocabularyProfilesDocument {
        try await fetchVocabularyProfiles()
    }

    func saveGlobalVocabulary(
        _ editedEntries: [VocabularyEntry],
        replacing baselineEntries: [VocabularyEntry]
    ) async throws -> [VocabularyEntry] {
        try await serializedMutation {
            let latestEntries = try VocabularyFile.load()
            let mergedEntries = Self.mergeVocabulary(
                latest: latestEntries,
                edited: editedEntries,
                baseline: baselineEntries
            )
            try VocabularyFile.save(mergedEntries)
            return mergedEntries
        }
    }

    func saveVocabularyProfile(
        _ editedProfile: VocabularyProfile,
        replacing baselineProfile: VocabularyProfile
    ) async throws -> VocabularyProfilesDocument {
        try await serializedMutation {
            var document = try await fetchVocabularyProfiles()
            let profileIndex = document.profiles.firstIndex {
                $0.bundle_id == editedProfile.bundle_id
            }
            var latestProfile = profileIndex.map { document.profiles[$0] }
                ?? VocabularyProfile(
                    bundle_id: editedProfile.bundle_id,
                    name: editedProfile.name,
                    entries: []
                )

            latestProfile.entries = Self.mergeVocabulary(
                latest: latestProfile.entries,
                edited: editedProfile.entries,
                baseline: baselineProfile.entries
            )
            latestProfile.name = editedProfile.name

            if let profileIndex {
                document.profiles[profileIndex] = latestProfile
            } else {
                document.profiles.append(latestProfile)
            }
            try await sendAuthenticatedPost(
                path: "api/vocabulary/profiles",
                body: document,
                operation: "Vocabulary profile update"
            )
            return document
        }
    }

    private static func mergeVocabulary(
        latest: [VocabularyEntry],
        edited: [VocabularyEntry],
        baseline: [VocabularyEntry]
    ) -> [VocabularyEntry] {
        let baselineByKey = Dictionary(
            baseline.map { (VocabularyEntry.normalized($0.spoken), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let editedByKey = Dictionary(
            edited.map { (VocabularyEntry.normalized($0.spoken), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let removedKeys = Set(baselineByKey.keys).subtracting(editedByKey.keys)
        var result = latest.filter {
            !removedKeys.contains(VocabularyEntry.normalized($0.spoken))
        }
        for (key, entry) in editedByKey where baselineByKey[key] != entry {
            if let index = result.firstIndex(where: {
                VocabularyEntry.normalized($0.spoken) == key
            }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result
    }

    func suggestions() async throws -> [VocabularySuggestion] {
        try await ensureRunning()
        let request = URLRequest(url: baseURL.appendingPathComponent("api/suggestions"))
        let data = try await send(request, operation: "Vocabulary suggestions")
        return try JSONDecoder().decode(SuggestionsResponse.self, from: data).suggestions
    }

    func acceptSuggestion(id: String, scope: SuggestionScope) async throws {
        try await authenticatedPost(
            path: "api/suggestions/accept",
            body: SuggestionAcceptanceRequest(id: id, scope: scope),
            operation: "Suggestion acceptance"
        )
    }

    func dismissSuggestion(id: String) async throws {
        try await authenticatedPost(
            path: "api/suggestions/dismiss",
            body: HistoryIDRequest(id: id),
            operation: "Suggestion dismissal"
        )
    }

    private func authenticatedPost<Body: Encodable>(
        path: String,
        body: Body,
        operation: String
    ) async throws {
        try await serializedMutation {
            try await sendAuthenticatedPost(path: path, body: body, operation: operation)
        }
    }

    private func sendAuthenticatedPost<Body: Encodable>(
        path: String,
        body: Body,
        operation: String
    ) async throws {
        _ = try await authenticatedJSONPost(path: path, body: body, operation: operation)
    }

    private func authenticatedJSONPost<Body: Encodable>(
        path: String,
        body: Body,
        operation: String,
        timeout: TimeInterval = 60
    ) async throws -> Data {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try workerToken(), forHTTPHeaderField: "X-Tiro-Worker-Token")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, operation: operation)
    }

    private func fetchVocabularyProfiles() async throws -> VocabularyProfilesDocument {
        try await ensureRunning()
        let request = URLRequest(url: baseURL.appendingPathComponent("api/vocabulary/profiles"))
        let data = try await send(request, operation: "Vocabulary profiles")
        return try JSONDecoder().decode(VocabularyProfilesDocument.self, from: data)
    }

    private func serializedMutation<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        try await mutationGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await mutationGate.release()
            return result
        } catch {
            await mutationGate.release()
            throw error
        }
    }

    private func setOriginHeader(
        _ value: String?,
        maximum: Int,
        field: String,
        on request: inout URLRequest
    ) {
        guard let value = Self.encodedHeaderValue(value, maximum: maximum) else { return }
        request.setValue(value, forHTTPHeaderField: field)
    }

    private static func encodedHeaderValue(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var encoded = ""
        for scalar in trimmed.unicodeScalars {
            guard let chunk = String(scalar).addingPercentEncoding(withAllowedCharacters: .tiroHeaderValue),
                  encoded.count + chunk.count <= maximum else { break }
            encoded += chunk
        }
        return encoded.isEmpty ? nil : encoded
    }

    private func send(_ request: URLRequest, operation: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "\(operation) failed with status \(http.statusCode)."
            throw WorkerError.server(message)
        }
        return data
    }

    private func isHealthy() async -> Bool {
        await workerState() == .compatible
    }

    private func workerState() async -> WorkerState {
        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/status"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let status = try? JSONDecoder().decode(WorkerStatus.self, from: data) else {
                return .unavailable
            }
            guard status.api_version == Self.supportedAPIVersion,
                  URL(fileURLWithPath: status.history_file).standardizedFileURL
                    == AppPaths.historyFile.standardizedFileURL else {
                return .incompatible
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/models"))
            request.setValue(try workerToken(), forHTTPHeaderField: "X-Tiro-Worker-Token")
            let (_, authResponse) = try await URLSession.shared.data(for: request)
            return (authResponse as? HTTPURLResponse)?.statusCode == 200
                ? .compatible
                : .incompatible
        } catch {
            return .unavailable
        }
    }

    private func stopIncompatibleWorker() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/shutdown"))
        request.httpMethod = "POST"
        request.setValue(try workerToken(), forHTTPHeaderField: "X-Tiro-Worker-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkerError.unavailable("An incompatible local worker is already running.")
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if await workerState() == .unavailable { return }
        }
        throw WorkerError.unavailable("The incompatible local worker did not stop.")
    }

    private func workerToken() throws -> String {
        if let token = try? String(contentsOf: AppPaths.workerTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        let token = UUID().uuidString
        try FileManager.default.createDirectory(
            at: AppPaths.workerTokenFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try token.write(to: AppPaths.workerTokenFile, atomically: true, encoding: .utf8)
        return token
    }

    func stopOwnedWorker() {
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
        logHandle = nil
    }
}

private struct WorkerStatus: Decodable {
    let api_version: Int
    let history_file: String
}

private struct HistoryResponse: Decodable {
    let entries: [HistoryEntry]
}

private struct ModelsResponse: Decodable {
    let models: [ManagedModel]

    private enum CodingKeys: String, CodingKey { case models }

    init(from decoder: Decoder) throws {
        if let direct = try? [ManagedModel](from: decoder) {
            models = direct
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? values.decode([ManagedModel].self, forKey: .models) {
            models = array
            return
        }
        let dictionary = try values.decode([String: ModelPayload].self, forKey: .models)
        models = dictionary.map(ManagedModel.init(key:payload:)).sorted { $0.key < $1.key }
    }
}

private struct ModelKeyRequest: Encodable {
    let key: String
    let model: String
}

private struct ModelComparisonRequest: Encodable {
    let history_id: String
    let model_keys: [String]
    let models: [String]
    let comparison_id: String
}

private struct ComparisonIDRequest: Encodable {
    let comparison_id: String
}

private struct ModelComparisonResponse: Decodable {
    let results: [ModelComparisonResult]

    private enum CodingKeys: String, CodingKey { case results, comparisons, models }

    init(from decoder: Decoder) throws {
        if let direct = try? [ModelComparisonResult](from: decoder) {
            results = direct
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try? values.decode([ModelComparisonResult].self, forKey: .results) {
            results = decoded
        } else if let decoded = try? values.decode([ModelComparisonResult].self, forKey: .comparisons) {
            results = decoded
        } else {
            results = try values.decode([ModelComparisonResult].self, forKey: .models)
        }
    }
}

private struct HistoryIDRequest: Encodable {
    let id: String
}

private struct HistoryCorrectionRequest: Encodable {
    let id: String
    let corrected_text: String
}

private struct RetentionRequest: Encodable {
    let days: Int
}

private struct SuggestionsResponse: Decodable {
    let suggestions: [VocabularySuggestion]
}

enum SuggestionScope: String, Encodable {
    case profile
    case global
}

private struct SuggestionAcceptanceRequest: Encodable {
    let id: String
    let scope: SuggestionScope
}

private enum WorkerState {
    case compatible
    case incompatible
    case unavailable
}

enum WorkerError: LocalizedError {
    case unavailable(String)
    case runtimeMissing(String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail.isEmpty
                ? "The local transcription worker did not start."
                : "The local transcription worker did not start: \(detail)"
        case .runtimeMissing(let path): return "The Python runtime is missing at \(path)."
        case .invalidResponse: return "The transcription worker returned an invalid response."
        case .server(let message): return message
        }
    }
}

private extension WorkerClient {
    func recentWorkerLog() -> String {
        guard let data = try? Data(contentsOf: AppPaths.workerLog),
              let contents = String(data: data, encoding: .utf8) else { return "" }
        return contents.split(separator: "\n").suffix(3).joined(separator: " ")
    }
}

private extension CharacterSet {
    static let tiroHeaderValue = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}

private actor WorkerMutationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !isLocked {
            isLocked = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
