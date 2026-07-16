import Foundation

@MainActor final class WorkerAPI {
    private let baseURL: URL
    private let transport: WorkerTransport
    private let ensureRunning: @MainActor () async throws -> Void
    private let authenticationToken: @MainActor () throws -> String

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8767")!,
        process: WorkerProcess,
        transport: WorkerTransport = WorkerTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        ensureRunning = process.ensureRunning
        authenticationToken = process.authenticationToken
    }

    init(
        baseURL: URL,
        transport: WorkerTransport,
        ensureRunning: @escaping @MainActor () async throws -> Void,
        authenticationToken: @escaping @MainActor () throws -> String
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.ensureRunning = ensureRunning
        self.authenticationToken = authenticationToken
    }

    func transcribe(
        wavURL: URL,
        model: DictationModel,
        originBundleID: String?,
        originName: String?
    ) async throws -> TranscriptionResponse {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(model.key, forHTTPHeaderField: "X-Parakeet-Model")
        let preferences = DictationPreferences.current
        request.setValue(preferences.mode.rawValue, forHTTPHeaderField: "X-Tiro-Mode")
        request.setValue(preferences.punctuation.rawValue, forHTTPHeaderField: "X-Tiro-Punctuation")
        request.setValue(
            DictationPreferences.language(for: model).rawValue,
            forHTTPHeaderField: "X-Tiro-Language"
        )
        try authenticate(&request)
        setOriginHeader(originBundleID, maximum: 255, field: "X-Tiro-Origin-Bundle-ID", on: &request)
        setOriginHeader(originName, maximum: 200, field: "X-Tiro-Origin-App-Name", on: &request)
        request.httpBody = try Data(contentsOf: wavURL)

        let data = try await transport.send(request, operation: "Transcription")
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    func preload(model: DictationModel) async throws {
        let availableModels = try await models()
        guard availableModels.contains(where: { $0.key == model.key && $0.installed }) else {
            throw WorkerError.server("Download \(model.name) before loading it.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/preload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue(model.key, forHTTPHeaderField: "X-Parakeet-Model")
        try authenticate(&request)
        _ = try await transport.send(request, operation: "Model preload")
    }

    func models() async throws -> [ManagedModel] {
        let data = try await authenticatedGet(path: "api/models", operation: "Model list")
        return try JSONDecoder().decode(ModelsResponse.self, from: data).models
    }

    func downloadModel(key: String) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/models/download",
            body: ModelKeyRequest(key: key, model: key),
            operation: "Model download",
            timeout: 7_200
        )
    }

    func deleteModel(key: String) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/models/delete",
            body: ModelKeyRequest(key: key, model: key),
            operation: "Model deletion"
        )
    }

    func snippets() async throws -> [UserSnippet] {
        let data = try await authenticatedGet(path: "api/snippets", operation: "Snippet list")
        return try JSONDecoder().decode(SnippetsResponse.self, from: data).snippets
    }

    func saveSnippet(_ snippet: UserSnippet) async throws -> UserSnippet {
        let data = try await authenticatedJSONPost(
            path: "api/snippets",
            body: snippet,
            operation: "Snippet save"
        )
        return try JSONDecoder().decode(UserSnippet.self, from: data)
    }

    func deleteSnippet(id: String) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/snippets/delete",
            body: HistoryIDRequest(id: id),
            operation: "Snippet deletion"
        )
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

    func searchHistory(query: String, limit: Int) async throws -> [HistoryEntry] {
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
        var request = URLRequest(url: url)
        try authenticate(&request)
        let data = try await transport.send(request, operation: "History search")
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
        var request = URLRequest(url: url)
        try authenticate(&request)
        return try await transport.send(request, operation: "Audio replay")
    }

    func deleteHistoryEntry(id: String) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/history/delete",
            body: HistoryIDRequest(id: id),
            operation: "History deletion"
        )
    }

    func correctHistoryEntry(id: String, correctedText: String) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/history/correction",
            body: HistoryCorrectionRequest(id: id, corrected_text: correctedText),
            operation: "History correction"
        )
    }

    func privacySettings() async throws -> PrivacySettings {
        let data = try await authenticatedGet(path: "api/privacy", operation: "Privacy settings")
        return try JSONDecoder().decode(PrivacySettings.self, from: data)
    }

    func updatePrivacySettings(_ settings: PrivacySettings) async throws -> PrivacySettings {
        let data = try await authenticatedJSONPost(
            path: "api/privacy",
            body: settings,
            operation: "Privacy settings update"
        )
        return try JSONDecoder().decode(PrivacySettings.self, from: data)
    }

    func deleteAllHistory() async throws {
        _ = try await authenticatedJSONPost(
            path: "api/history/delete-all",
            body: ConfirmationRequest(confirm: true),
            operation: "History deletion"
        )
    }

    func vocabularyProfiles() async throws -> VocabularyProfilesDocument {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/vocabulary/profiles"))
        try authenticate(&request)
        let data = try await transport.send(request, operation: "Vocabulary profiles")
        return try JSONDecoder().decode(VocabularyProfilesDocument.self, from: data)
    }

    func saveVocabularyProfiles(_ document: VocabularyProfilesDocument) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/vocabulary/profiles",
            body: document,
            operation: "Vocabulary profile update"
        )
    }

    func suggestions() async throws -> [VocabularySuggestion] {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/suggestions"))
        try authenticate(&request)
        let data = try await transport.send(request, operation: "Vocabulary suggestions")
        return try JSONDecoder().decode(SuggestionsResponse.self, from: data).suggestions
    }

    func acceptSuggestion(id: String, scope: SuggestionScope) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/suggestions/accept",
            body: SuggestionAcceptanceRequest(id: id, scope: scope),
            operation: "Suggestion acceptance"
        )
    }

    func dismissSuggestion(id: String) async throws {
        _ = try await authenticatedJSONPost(
            path: "api/suggestions/dismiss",
            body: HistoryIDRequest(id: id),
            operation: "Suggestion dismissal"
        )
    }

    private func authenticatedGet(path: String, operation: String) async throws -> Data {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        try authenticate(&request)
        return try await transport.send(request, operation: operation)
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
        try authenticate(&request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await transport.send(request, operation: operation)
    }

    private func authenticate(_ request: inout URLRequest) throws {
        request.setValue(
            try authenticationToken(),
            forHTTPHeaderField: "X-Tiro-Worker-Token"
        )
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

private struct SnippetsResponse: Decodable {
    let snippets: [UserSnippet]
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

private struct ConfirmationRequest: Encodable {
    let confirm: Bool
}

private struct SuggestionsResponse: Decodable {
    let suggestions: [VocabularySuggestion]
}

private struct SuggestionAcceptanceRequest: Encodable {
    let id: String
    let scope: SuggestionScope
}

private extension CharacterSet {
    static let tiroHeaderValue = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~")
    )
}
