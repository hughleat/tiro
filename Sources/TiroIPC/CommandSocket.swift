import Darwin
import Foundation

public final class TiroCommandSocketClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (TiroCommandEvent) -> Void

    public let socketURL: URL
    public let timeout: TimeInterval

    public init(
        socketURL: URL = TiroCommandSocketPath.defaultURL(),
        timeout: TimeInterval = TiroProtocolLimits.defaultResponseTimeout
    ) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    public func send(
        _ request: TiroCommandRequest,
        onEvent: EventHandler? = nil
    ) throws -> TiroCommandMessage {
        _ = try request.validated()
        try TiroCommandSocketPath.validate(socketURL)
        guard timeout.isFinite, timeout > 0,
              timeout <= TiroProtocolLimits.defaultResponseTimeout else {
            throw TiroSocketError.invalidTimeout
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var payload = try encoder.encode(request)
        guard payload.count <= TiroProtocolLimits.maximumRequestBytes else {
            throw TiroProtocolError.requestTooLarge
        }
        payload.append(0x0A)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TiroSocketError.systemCall("socket", errno)
        }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw TiroSocketError.systemCall("setsockopt", errno)
        }

        try connect(descriptor)
        try TiroCommandSocketSecurity.validatePeer(descriptor)
        try writeAll(payload, to: descriptor, timeout: timeout)
        return try readResponse(
            from: descriptor,
            request: request,
            onEvent: onEvent
        )
    }

    private func connect(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path)
        }
        let length = socklen_t(
            MemoryLayout<sa_family_t>.size + path.count
        )
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            throw TiroSocketError.connectionFailed(path: socketURL.path, code: errno)
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        timeout: TimeInterval
    ) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TiroSocketError.systemCall("fcntl", errno)
        }
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw TiroSocketError.timedOut }
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let milliseconds = Int32(
                    min(Double(Int32.max), ceil(remaining * 1_000))
                )
                let pollResult = poll(&pollDescriptor, 1, milliseconds)
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else {
                    if pollResult == 0 { throw TiroSocketError.timedOut }
                    throw TiroSocketError.systemCall("poll", errno)
                }
                guard pollDescriptor.revents & Int16(POLLNVAL | POLLERR) == 0,
                      pollDescriptor.revents & Int16(POLLOUT) != 0 else {
                    throw TiroSocketError.connectionClosed
                }

                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, (errno == EINTR || errno == EAGAIN) {
                    continue
                } else if written < 0, (errno == EPIPE || errno == ECONNRESET) {
                    throw TiroSocketError.connectionClosed
                } else {
                    throw TiroSocketError.systemCall("write", errno)
                }
            }
        }
    }

    private func readResponse(
        from descriptor: Int32,
        request: TiroCommandRequest,
        onEvent: EventHandler?
    ) throws -> TiroCommandMessage {
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        var pending = Data()
        var totalBytes = 0
        var messageCount = 0

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TiroSocketError.timedOut }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1_000)))
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else {
                if pollResult == 0 { throw TiroSocketError.timedOut }
                throw TiroSocketError.systemCall("poll", errno)
            }

            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw TiroSocketError.systemCall("read", errno)
            }
            guard count > 0 else {
                if !pending.isEmpty {
                    throw TiroProtocolError.incompleteResponse
                }
                throw TiroProtocolError.incompleteResponse
            }

            pending.append(contentsOf: buffer.prefix(count))
            totalBytes += count
            guard totalBytes <= TiroProtocolLimits.maximumResponseBytes else {
                throw TiroProtocolError.responseTooLarge
            }
            guard pending.count <= TiroProtocolLimits.maximumMessageBytes else {
                throw TiroProtocolError.messageTooLarge
            }

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                messageCount += 1
                guard messageCount <= TiroProtocolLimits.maximumMessages else {
                    throw TiroProtocolError.tooManyMessages
                }
                let message: TiroCommandMessage
                do {
                    message = try decoder.decode(TiroCommandMessage.self, from: line)
                } catch {
                    throw TiroProtocolError.unexpectedResponse(
                        "Tiro sent malformed command data."
                    )
                }
                _ = try message.validated(for: request)
                if message.type == .event {
                    if let event = message.event { onEvent?(event) }
                } else {
                    return message
                }
            }
        }
    }
}

public enum TiroCommandSocketSecurity {
    public static func validatePeer(
        _ descriptor: Int32,
        expectedUID: uid_t = geteuid()
    ) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
            throw TiroSocketError.systemCall("getpeereid", errno)
        }
        guard peerUID == expectedUID else {
            throw TiroSocketError.peerUIDMismatch(
                expected: UInt32(expectedUID),
                actual: UInt32(peerUID)
            )
        }
    }
}

public enum TiroSocketError: Error, Equatable, LocalizedError {
    case invalidSocketPath
    case unsafeSocketDirectory
    case invalidTimeout
    case connectionFailed(path: String, code: Int32)
    case peerUIDMismatch(expected: UInt32, actual: UInt32)
    case systemCall(String, Int32)
    case connectionClosed
    case timedOut

    public var isRetryableConnectionFailure: Bool {
        if case .connectionFailed(_, let code) = self {
            return code == ENOENT || code == ECONNREFUSED
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            "The Tiro command socket path is invalid."
        case .unsafeSocketDirectory:
            "The Tiro command socket must be inside a dedicated Tiro directory."
        case .invalidTimeout:
            "The Tiro command timeout is invalid."
        case .connectionFailed(let path, let code):
            "Could not connect to Tiro at \(path): \(Self.description(for: code))."
        case .peerUIDMismatch:
            "The Tiro command socket belongs to another user."
        case .systemCall(let operation, let code):
            "\(operation) failed: \(Self.description(for: code))."
        case .connectionClosed:
            "The Tiro command connection closed unexpectedly."
        case .timedOut:
            "Tiro did not respond before the command timed out."
        }
    }

    private static func description(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}
