import Darwin
import Foundation
import Testing
@testable import TiroIPC

@Suite(.serialized)
struct CommandSocketTests {
    @Test
    func clientAuthenticatesPeerAndReadsEventsThenResult() async throws {
        let server = try TestSocketServer { request in
            [
                .event(id: request.id, name: "transcribing", fraction: 0.5),
                .success(
                    id: request.id,
                    result: TiroCommandResult(
                        kind: "transcript",
                        text: "Hello",
                        model: "coreml-compact"
                    )
                ),
            ]
        }
        defer { server.close() }
        let events = EventRecorder()
        let request = TiroCommandRequest.status()

        let response = try TiroCommandSocketClient(
            socketURL: server.url,
            timeout: 2
        ).send(request) { event in
            events.append(event)
        }

        #expect(response.result?.text == "Hello")
        #expect(events.values.map(\.name) == ["transcribing"])
        #expect(try server.receivedRequest()?.command == .status)
    }

    @Test
    func clientRejectsMismatchedResponseID() throws {
        let server = try TestSocketServer { _ in
            [.success(
                id: UUID().uuidString.lowercased(),
                result: TiroCommandResult(kind: "status", state: "idle")
            )]
        }
        defer { server.close() }

        #expect(throws: TiroProtocolError.self) {
            try TiroCommandSocketClient(socketURL: server.url, timeout: 2)
                .send(.status())
        }
    }

    @Test
    func clientRejectsOversizedMessage() throws {
        let server = try TestSocketServer(rawResponse: Data(
            repeating: UInt8(ascii: "x"),
            count: TiroProtocolLimits.maximumMessageBytes + 1
        ))
        defer { server.close() }

        #expect(throws: TiroProtocolError.self) {
            try TiroCommandSocketClient(socketURL: server.url, timeout: 2)
                .send(.status())
        }
    }

    @Test
    func peerValidationAcceptsCurrentUser() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        try TiroCommandSocketSecurity.validatePeer(descriptors[0])
        #expect(throws: TiroSocketError.self) {
            try TiroCommandSocketSecurity.validatePeer(
                descriptors[0],
                expectedUID: geteuid() &+ 1
            )
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TiroCommandEvent] = []

    var values: [TiroCommandEvent] {
        lock.withLock { storage }
    }

    func append(_ event: TiroCommandEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class TestSocketServer: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var storedRequest: TiroCommandRequest?

    init(
        responses: @escaping @Sendable (TiroCommandRequest) -> [TiroCommandMessage]
    ) throws {
        let identifier = UUID().uuidString.prefix(12)
        let root = URL(
            fileURLWithPath: "/tmp/tiro-ipc-\(identifier)",
            isDirectory: true
        )
        let directory = root.appendingPathComponent("Tiro", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("command.sock")
        descriptor = try Self.makeListener(url: url)
        task = Task.detached { [weak self] in
            guard let self else { return }
            self.serve { request in
                let encoder = JSONEncoder()
                return responses(request).reduce(into: Data()) { data, response in
                    if let encoded = try? encoder.encode(response) {
                        data.append(encoded)
                        data.append(0x0A)
                    }
                }
            }
        }
    }

    init(rawResponse: Data) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiro-ipc-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("Tiro", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("command.sock")
        descriptor = try Self.makeListener(url: url)
        task = Task.detached { [weak self] in
            self?.serve { _ in rawResponse }
        }
    }

    func receivedRequest() throws -> TiroCommandRequest? {
        lock.withLock { storedRequest }
    }

    func close() {
        task?.cancel()
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func serve(response: (TiroCommandRequest) -> Data) {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        try? TiroCommandSocketSecurity.validatePeer(client)
        var requestData = Data()
        var byte: UInt8 = 0
        while Darwin.read(client, &byte, 1) == 1, byte != 0x0A {
            requestData.append(byte)
        }
        guard let request = try? JSONDecoder().decode(
            TiroCommandRequest.self,
            from: requestData
        ) else { return }
        lock.withLock { storedRequest = request }
        let data = response(request)
        data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(client, address.advanced(by: offset), buffer.count - offset)
                if count <= 0 { break }
                offset += count
            }
        }
    }

    private static func makeListener(url: URL) throws -> Int32 {
        try TiroCommandSocketPath.validate(url)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: path)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sa_family_t>.size + path.count)
                )
            }
        }
        guard result == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        return descriptor
    }
}
