import Foundation
import Testing
@testable import Tiro

final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storedRequests.append(request) }
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    enum MockError: Error { case handlerMissing, invalidURL, invalidResponse }

    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]

    static func install(
        for host: String,
        _ handler: @escaping (URLRequest) throws -> (Int, Data)
    ) {
        lock.withLock { handlers[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url else { throw MockError.invalidURL }
            guard let handler = Self.lock.withLock({ Self.handlers[url.host ?? ""] }) else {
                throw MockError.handlerMissing
            }
            let (status, data) = try handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else { throw MockError.invalidResponse }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct WorkerAPITests {
    private func makeTransport() -> (WorkerTransport, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (WorkerTransport(session: session), session)
    }

    @Test @MainActor
    func testEveryAPIRequestIsAuthenticated() async throws {
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }
        let recorder = RequestRecorder()
        MockURLProtocol.install(for: "worker.test") { request in
            recorder.append(request)
            return (200, Self.responseBody(for: request))
        }
        var ensureRunningCount = 0
        let api = WorkerAPI(
            baseURL: URL(string: "https://worker.test")!,
            transport: transport,
            ensureRunning: { ensureRunningCount += 1 },
            authenticationToken: { "test-token" }
        )
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("wav".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        _ = try await api.transcribe(
            wavURL: audioURL,
            model: DictationModel.all[0],
            originBundleID: "com.example.editor",
            originName: "Editor"
        )
        try await api.preload(model: DictationModel.all[0])
        _ = try await api.models()
        try await api.downloadModel(key: "compact")
        try await api.deleteModel(key: "compact")
        _ = try await api.snippets()
        _ = try await api.saveSnippet(UserSnippet(id: "s", trigger: "sig", content: "Regards"))
        try await api.deleteSnippet(id: "s")
        _ = try await api.compareModels(
            historyID: "h",
            modelKeys: ["compact", "qwen"],
            comparisonID: "c"
        )
        await api.cancelComparison(id: "c")
        _ = try await api.searchHistory(query: "private words", limit: 20)
        _ = try await api.historyAudio(id: "h")
        try await api.deleteHistoryEntry(id: "h")
        try await api.correctHistoryEntry(id: "h", correctedText: "corrected")
        try await api.setHistoryRetention(days: 30)
        _ = try await api.vocabularyProfiles()
        try await api.saveVocabularyProfiles(VocabularyProfilesDocument())
        _ = try await api.suggestions()
        try await api.acceptSuggestion(id: "v", scope: .global)
        try await api.dismissSuggestion(id: "v")

        let requests = recorder.requests
        #expect(ensureRunningCount == 20)
        #expect(requests.count == 21)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Tiro-Worker-Token") == "test-token"
        })
        #expect(Set(requests.map(Self.requestKey)) == Set([
            "POST /api/transcribe",
            "GET /api/models",
            "POST /api/preload",
            "POST /api/models/download",
            "POST /api/models/delete",
            "GET /api/snippets",
            "POST /api/snippets",
            "POST /api/snippets/delete",
            "POST /api/models/compare",
            "POST /api/models/compare/cancel",
            "GET /api/history",
            "GET /api/history/audio",
            "POST /api/history/delete",
            "POST /api/history/correction",
            "POST /api/history/retention",
            "GET /api/vocabulary/profiles",
            "POST /api/vocabulary/profiles",
            "GET /api/suggestions",
            "POST /api/suggestions/accept",
            "POST /api/suggestions/dismiss",
        ]))
    }

    private static func requestKey(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
    }

    private static func responseBody(for request: URLRequest) -> Data {
        let value: String
        switch request.url?.path {
        case "/api/transcribe":
            value = #"{"timestamp":"now","model":"compact","audio_file":"a.wav","transcription_seconds":0.1,"text":"hello"}"#
        case "/api/models":
            value = #"{"models":[{"key":"compact","installed":true}]}"#
        case "/api/snippets" where request.httpMethod == "GET":
            value = #"{"snippets":[]}"#
        case "/api/snippets":
            value = #"{"id":"s","trigger":"sig","content":"Regards"}"#
        case "/api/models/compare":
            value = #"{"results":[]}"#
        case "/api/history":
            value = #"{"entries":[]}"#
        case "/api/history/audio":
            value = "audio"
        case "/api/vocabulary/profiles":
            value = request.httpMethod == "GET" ? #"{"version":1,"profiles":[]}"# : "{}"
        case "/api/suggestions":
            value = #"{"suggestions":[]}"#
        default:
            value = "{}"
        }
        return Data(value.utf8)
    }
}
