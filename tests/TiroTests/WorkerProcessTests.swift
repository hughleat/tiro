import Foundation
import Testing
@testable import Tiro

struct WorkerProcessTests {
    private func makeTransport() -> (WorkerTransport, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (WorkerTransport(session: session), session)
    }

    @Test @MainActor
    func testConcurrentEnsureRunningCallsShareOneReconciliation() async throws {
        var reconciliationCount = 0
        let process = WorkerProcess(reconcileOverride: {
            reconciliationCount += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        })

        async let first: Void = process.ensureRunning()
        async let second: Void = process.ensureRunning()
        async let third: Void = process.ensureRunning()
        _ = try await (first, second, third)

        #expect(reconciliationCount == 1)
    }

    @Test @MainActor
    func testAuthenticationTokenIsCreatedPrivatelyAndReused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tokenFile = directory.appendingPathComponent("worker.token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = WorkerProcess(tokenFile: tokenFile)

        let first = try process.authenticationToken()
        let second = try process.authenticationToken()

        #expect(!first.isEmpty)
        #expect(second == first)
        #expect(try String(contentsOf: tokenFile, encoding: .utf8) == first)
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test @MainActor
    func testCompatibilityRequestsAreAuthenticated() async throws {
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }
        let recorder = RequestRecorder()
        MockURLProtocol.install(for: "process.test") { request in
            recorder.append(request)
            if request.url?.path == "/api/status" {
                let body = try JSONSerialization.data(withJSONObject: [
                    "api_version": 6,
                    "history_file": AppPaths.historyFile.path,
                ])
                return (200, body)
            }
            return (200, Data("{}".utf8))
        }
        let tokenFile = try makeTokenFile(containing: "process-token")
        defer { try? FileManager.default.removeItem(at: tokenFile.deletingLastPathComponent()) }
        let process = WorkerProcess(
            baseURL: URL(string: "https://process.test")!,
            transport: transport,
            tokenFile: tokenFile
        )

        #expect(await process.workerState() == .compatible)
        #expect(recorder.requests.map(\.url?.path) == ["/api/status", "/api/models"])
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Tiro-Worker-Token") == "process-token"
        })
    }

    @Test @MainActor
    func testIncompatibleWorkerShutdownIsAuthenticated() async throws {
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }
        let recorder = RequestRecorder()
        MockURLProtocol.install(for: "shutdown.test") { request in
            recorder.append(request)
            if request.url?.path == "/api/shutdown" { return (200, Data("{}".utf8)) }
            throw URLError(.cannotConnectToHost)
        }
        let tokenFile = try makeTokenFile(containing: "shutdown-token")
        defer { try? FileManager.default.removeItem(at: tokenFile.deletingLastPathComponent()) }
        let process = WorkerProcess(
            baseURL: URL(string: "https://shutdown.test")!,
            transport: transport,
            tokenFile: tokenFile
        )

        try await process.stopIncompatibleWorker()

        #expect(recorder.requests.first?.url?.path == "/api/shutdown")
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Tiro-Worker-Token") == "shutdown-token"
        })
    }

    private func makeTokenFile(containing token: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("worker.token")
        try PrivateFilePermissions.write(Data(token.utf8), to: file)
        return file
    }
}
