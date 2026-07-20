import Darwin
import Foundation
import Testing
@testable import TiroIPC

@Suite(.serialized)
struct CommandSocketServerTests {
    @Test
    func serverCreatesPrivatePathsAndCleansUp() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        let server = TiroCommandSocketServer(socketURL: fixture.socketURL)

        try server.start { _, responder in
            try await responder.sendSuccess(
                TiroCommandResult(kind: "status", state: "idle")
            )
        }

        #expect(server.isRunning)
        #expect(try permissions(fixture.directory) == 0o700)
        #expect(try permissions(fixture.socketURL) == 0o600)
        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    @Test
    func serverNeverChangesPermissionsOfExistingDirectory() throws {
        let identifier = UUID().uuidString.prefix(12)
        let root = URL(
            fileURLWithPath: "/tmp/tiro-parent-\(identifier)",
            isDirectory: true
        )
        let directory = root.appendingPathComponent("Tiro", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let server = TiroCommandSocketServer(
            socketURL: directory.appendingPathComponent("command.sock")
        )
        #expect(throws: TiroCommandSocketServerError.unsafeParentDirectory) {
            try server.start { _, _ in }
        }
        #expect(try permissions(directory) == 0o755)
    }

    @Test
    func serverSendsEventsAndOneTerminalResponse() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        let server = TiroCommandSocketServer(socketURL: fixture.socketURL)
        defer { server.stop() }
        let terminalCheck = LockedValue<Bool>(false)

        try server.start { _, responder in
            try await responder.sendEvent(name: "working", fraction: 0.5)
            try await responder.sendSuccess(
                TiroCommandResult(kind: "status", state: "ready")
            )
            do {
                try await responder.sendFailure(
                    code: "late",
                    message: "Too late"
                )
            } catch TiroCommandSocketServerError.terminalAlreadySent {
                terminalCheck.set(true)
            }
        }

        let events = LockedValue<[TiroCommandEvent]>([])
        let response = try TiroCommandSocketClient(
            socketURL: fixture.socketURL,
            timeout: 10
        ).send(.status()) { event in
            events.mutate { $0.append(event) }
        }

        #expect(response.result?.state == "ready")
        #expect(events.value.map(\.name) == ["working"])
        #expect(waitUntil { terminalCheck.value })
    }

    @Test
    func serverCancelsHandlerWhenClientDisconnects() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        let server = TiroCommandSocketServer(socketURL: fixture.socketURL)
        defer { server.stop() }
        let handlerStarted = LockedValue(false)
        let handlerCancelled = LockedValue(false)
        try server.start { _, _ in
            handlerStarted.set(true)
            try await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                try Task.checkCancellation()
            } onCancel: {
                handlerCancelled.set(true)
            }
        }

        let client = try connectWithoutReading(to: fixture.socketURL)
        try sendStatusRequest(to: client)
        #expect(waitUntil { handlerStarted.value })
        Darwin.close(client)
        #expect(waitUntil { handlerCancelled.value })
    }

    @Test
    func serverReplacesSameUserStaleSocket() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        try makeStaleSocket(at: fixture.socketURL)
        let server = TiroCommandSocketServer(socketURL: fixture.socketURL)
        defer { server.stop() }

        try server.start { _, responder in
            try await responder.sendSuccess(
                TiroCommandResult(kind: "status", state: "idle")
            )
        }

        let response = try TiroCommandSocketClient(
            socketURL: fixture.socketURL,
            timeout: 10
        ).send(.status())
        #expect(response.result?.state == "idle")
    }

    @Test
    func serverNeverRemovesNonSocketAtDestination() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        try Data("do not remove".utf8).write(to: fixture.socketURL)
        let server = TiroCommandSocketServer(socketURL: fixture.socketURL)

        #expect(throws: TiroCommandSocketServerError.self) {
            try server.start { _, _ in }
        }
        #expect(
            try String(contentsOf: fixture.socketURL, encoding: .utf8)
                == "do not remove"
        )
    }

    @Test
    func secondServerCannotReplaceLiveServer() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        let first = TiroCommandSocketServer(socketURL: fixture.socketURL)
        let second = TiroCommandSocketServer(socketURL: fixture.socketURL)
        defer {
            first.stop()
            second.stop()
        }
        try first.start { _, responder in
            try await responder.sendSuccess(
                TiroCommandResult(kind: "status", state: "idle")
            )
        }

        #expect(throws: TiroCommandSocketServerError.self) {
            try second.start { _, _ in }
        }
        #expect(first.isRunning)
    }

    @Test
    func incompleteHandlerGetsTerminalFailure() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        let server = TiroCommandSocketServer(socketURL: fixture.socketURL)
        defer { server.stop() }
        try server.start { _, _ in }

        let response = try TiroCommandSocketClient(
            socketURL: fixture.socketURL,
            timeout: 10
        ).send(.status())

        #expect(response.type == .failure)
        #expect(response.error?.code == "handler_incomplete")
    }

    @Test
    func stopRemainsPromptWhenClientDoesNotRead() throws {
        let fixture = try ServerFixture()
        defer { fixture.remove() }
        let server = TiroCommandSocketServer(
            socketURL: fixture.socketURL,
            requestTimeout: 5
        )
        let handlerStarted = LockedValue(false)
        let handlerStopped = LockedValue(false)
        try server.start { _, responder in
            handlerStarted.set(true)
            try await withTaskCancellationHandler {
                for index in 0..<1_000 {
                    try Task.checkCancellation()
                    try await responder.sendEvent(
                        name: "output",
                        detail: "\(index)-" + String(repeating: "x", count: 32_000)
                    )
                }
            } onCancel: {
                handlerStopped.set(true)
            }
        }

        let client = try connectWithoutReading(to: fixture.socketURL)
        defer { Darwin.close(client) }
        try sendStatusRequest(to: client)
        #expect(waitUntil { handlerStarted.value })

        let started = Date()
        server.stop()
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(waitUntil { handlerStopped.value })
    }
}

private struct ServerFixture {
    let directory: URL
    let socketURL: URL

    init() throws {
        let identifier = UUID().uuidString.prefix(12)
        let root = URL(
            fileURLWithPath: "/tmp/tiro-server-\(identifier)",
            isDirectory: true
        )
        directory = root.appendingPathComponent("Tiro", isDirectory: true)
        socketURL = directory.appendingPathComponent("command.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

private func connectWithoutReading(to url: URL) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw TiroSocketError.systemCall("socket", errno)
    }
    do {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: path)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sa_family_t>.size + path.count)
                )
            }
        }
        guard result == 0 else {
            throw TiroSocketError.systemCall("connect", errno)
        }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func sendStatusRequest(to descriptor: Int32) throws {
    var data = try JSONEncoder().encode(TiroCommandRequest.status())
    data.append(0x0A)
    let written = data.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    guard written == data.count else {
        throw TiroSocketError.systemCall("write", errno)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func makeStaleSocket(at url: URL) throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw TiroSocketError.systemCall("socket", errno)
    }
    defer { close(descriptor) }
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
    guard result == 0 else {
        throw TiroSocketError.systemCall("bind", errno)
    }
}

private func waitUntil(
    timeout: TimeInterval = 1,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
