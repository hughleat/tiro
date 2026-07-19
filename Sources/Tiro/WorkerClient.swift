import Foundation
import TiroRecognition

@MainActor final class WorkerClient {
    private let process: WorkerProcess
    private let api: WorkerAPI
    private let coreML = CoreMLParakeetEngine(
        modelsRootDirectory: AppPaths.coreMLModelsDirectory
    )
    private let mutationGate = WorkerMutationGate()

    init() {
        let transport = WorkerTransport()
        let process = WorkerProcess(transport: transport)
        self.process = process
        api = WorkerAPI(process: process, transport: transport)
    }

    func ensureRunning() async throws {
        try await process.ensureRunning()
    }

    func transcribe(
        wavURL: URL,
        model: DictationModel,
        originBundleID: String? = nil,
        originName: String? = nil
    ) async throws -> TranscriptionResponse {
        let preferences = DictationPreferences.snapshot(for: model)
        if model.key == DictationModel.coreMLCompactKey {
            try await api.unloadModel()
            try await coreML.preload()
            let raw = try await coreML.transcribe(wavURL)
            return try await api.finalizeNativeTranscription(
                wavURL: wavURL,
                rawText: raw.text,
                transcriptionSeconds: raw.transcriptionSeconds,
                originBundleID: originBundleID,
                originName: originName,
                preferences: preferences
            )
        }
        try await coreML.unload()
        return try await api.transcribe(
            wavURL: wavURL,
            model: model,
            originBundleID: originBundleID,
            originName: originName,
            preferences: preferences
        )
    }

    func preload(model: DictationModel) async throws {
        if model.key == DictationModel.coreMLCompactKey {
            try await api.unloadModel()
            try await coreML.preload()
            return
        }
        try await coreML.unload()
        try await api.preload(model: model)
    }

    func activate(model: DictationModel) async throws {
        try await serializedMutation {
            if model.key == DictationModel.coreMLCompactKey {
                try await self.api.unloadModel()
            } else {
                try await self.coreML.unload()
            }
        }
    }

    func models() async throws -> [ManagedModel] {
        let workerModels = try await api.models()
        let status = await coreML.status()
        let nativeModel = ManagedModel(
            key: DictationModel.coreMLCompactKey,
            installedSizeBytes: status.installed ? status.sizeBytes : nil,
            installed: status.installed,
            downloading: status.activity == .downloading,
            deleting: status.activity == .deleting,
            loaded: status.loaded,
            downloadError: status.lastError,
            progress: status.downloadProgress,
            state: status.activity == .idle
                ? (status.loaded ? "ready" : status.installed ? "installed" : "not_installed")
                : status.activity.rawValue
        )
        return [nativeModel] + workerModels
    }

    func downloadModel(key: String) async throws {
        if key == DictationModel.coreMLCompactKey {
            try await serializedMutation { try await self.coreML.download() }
            return
        }
        try await serializedMutation { try await self.api.downloadModel(key: key) }
    }

    func deleteModel(key: String) async throws {
        if key == DictationModel.coreMLCompactKey {
            try await serializedMutation { try await self.coreML.delete() }
            return
        }
        try await serializedMutation { try await self.api.deleteModel(key: key) }
    }

    func snippets() async throws -> [UserSnippet] {
        try await api.snippets()
    }

    func saveSnippet(_ snippet: UserSnippet) async throws -> UserSnippet {
        try await serializedMutation { try await self.api.saveSnippet(snippet) }
    }

    func deleteSnippet(id: String) async throws {
        try await serializedMutation { try await self.api.deleteSnippet(id: id) }
    }

    func compareModels(
        historyID: String,
        modelKeys: [String],
        comparisonID: String
    ) async throws -> [ModelComparisonResult] {
        try await api.compareModels(
            historyID: historyID,
            modelKeys: modelKeys,
            comparisonID: comparisonID
        )
    }

    func cancelComparison(id: String) async {
        await api.cancelComparison(id: id)
    }

    func searchHistory(query: String = "", limit: Int = 200) async throws -> [HistoryEntry] {
        try await api.searchHistory(query: query, limit: limit)
    }

    func historyAudio(id: String) async throws -> Data {
        try await api.historyAudio(id: id)
    }

    func deleteHistoryEntry(id: String) async throws {
        try await serializedMutation { try await self.api.deleteHistoryEntry(id: id) }
    }

    func correctHistoryEntry(id: String, correctedText: String) async throws {
        try await serializedMutation {
            try await self.api.correctHistoryEntry(id: id, correctedText: correctedText)
        }
    }

    func privacySettings() async throws -> PrivacySettings {
        try await api.privacySettings()
    }

    func updatePrivacySettings(_ settings: PrivacySettings) async throws -> PrivacySettings {
        try Self.validatePrivacySettings(settings)
        return try await serializedMutation {
            try await self.api.updatePrivacySettings(settings)
        }
    }

    func deleteAllHistory() async throws {
        try await serializedMutation { try await self.api.deleteAllHistory() }
    }

    nonisolated static func validatePrivacySettings(_ settings: PrivacySettings) throws {
        guard !settings.store_recordings || settings.store_history else {
            throw WorkerError.server("Recordings can only be kept when transcription history is saved.")
        }
        guard [0, 1, 7, 30, 90].contains(settings.retention_days) else {
            throw WorkerError.server("Retention must be Forever, 1, 7, 30, or 90 days.")
        }
    }

    func vocabularyProfiles() async throws -> VocabularyProfilesDocument {
        try await api.vocabularyProfiles()
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
            var document = try await self.api.vocabularyProfiles()
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
            try await self.api.saveVocabularyProfiles(document)
            return document
        }
    }

    func suggestions() async throws -> [VocabularySuggestion] {
        try await api.suggestions()
    }

    func acceptSuggestion(id: String, scope: SuggestionScope) async throws {
        try await serializedMutation {
            try await self.api.acceptSuggestion(id: id, scope: scope)
        }
    }

    func dismissSuggestion(id: String) async throws {
        try await serializedMutation { try await self.api.dismissSuggestion(id: id) }
    }

    func stopOwnedWorker() {
        process.stopOwnedWorker()
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
}

enum SuggestionScope: String, Encodable {
    case profile
    case global
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
