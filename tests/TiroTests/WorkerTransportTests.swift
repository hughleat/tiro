import Foundation
import Testing
@testable import Tiro

@Suite(.serialized)
struct WorkerTransportTests {
    private func makeTransport() -> (WorkerTransport, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (WorkerTransport(session: session), session)
    }

    @Test
    func testSendDecodesServerErrorMessage() async throws {
        MockURLProtocol.install(for: "server-error.test") { _ in
            (422, Data(#"{"error":"Model is not installed."}"#.utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await transport.send(
                URLRequest(url: URL(string: "https://server-error.test/api/preload")!),
                operation: "Model preload"
            )
            Issue.record("Expected a server error")
        } catch WorkerError.server(let message) {
            #expect(message == "Model is not installed.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testSendPreservesTimeoutError() async throws {
        MockURLProtocol.install(for: "timeout.test") { _ in throw URLError(.timedOut) }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await transport.send(
                URLRequest(url: URL(string: "https://timeout.test/api/transcribe")!),
                operation: "Transcription"
            )
            Issue.record("Expected a timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
