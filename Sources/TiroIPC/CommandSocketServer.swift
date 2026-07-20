import Darwin
import Foundation

public final class TiroCommandSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (
        TiroCommandRequest,
        TiroCommandResponder
    ) async throws -> Void

    public let socketURL: URL
    public let requestTimeout: TimeInterval

    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(
        label: "local.tiro.command-socket.accept",
        qos: .utility
    )
    private var listener: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var socketIdentity: FileIdentity?
    private var handler: Handler?
    private var connections: [ObjectIdentifier: ManagedSocket] = [:]
    private var handlerTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(
        socketURL: URL = TiroCommandSocketPath.defaultURL(),
        requestTimeout: TimeInterval = 5
    ) {
        self.socketURL = socketURL
        self.requestTimeout = requestTimeout
    }

    public var isRunning: Bool {
        stateLock.withLock { listener >= 0 }
    }

    public func start(handler: @escaping Handler) throws {
        try TiroCommandSocketPath.validate(socketURL)
        guard requestTimeout.isFinite, requestTimeout > 0, requestTimeout <= 60 else {
            throw TiroCommandSocketServerError.invalidRequestTimeout
        }

        let descriptor: Int32 = try stateLock.withLock {
            guard listener < 0 else {
                throw TiroCommandSocketServerError.alreadyRunning
            }
            try Self.preparePrivateDirectory(socketURL.deletingLastPathComponent())
            let acquiredLock = try Self.acquireServerLock(for: socketURL)
            do {
                try Self.removeStaleSocketIfSafe(at: socketURL)
                let listener = try Self.makeListener(at: socketURL)
                let identity = try Self.identity(
                    at: socketURL,
                    expectedType: S_IFSOCK
                )
                self.listener = listener
                lockDescriptor = acquiredLock
                socketIdentity = identity
                self.handler = handler
                return listener
            } catch {
                flock(acquiredLock, LOCK_UN)
                close(acquiredLock)
                throw error
            }
        }

        acceptQueue.async { [weak self] in
            self?.acceptConnections(listener: descriptor)
        }
    }

    public func stop() {
        let stopped: (
            listener: Int32,
            lockDescriptor: Int32,
            identity: FileIdentity?,
            connections: [ManagedSocket],
            handlerTasks: [Task<Void, Never>]
        ) = stateLock.withLock {
            let value = (
                listener,
                lockDescriptor,
                socketIdentity,
                Array(connections.values),
                Array(handlerTasks.values)
            )
            listener = -1
            lockDescriptor = -1
            socketIdentity = nil
            handler = nil
            connections.removeAll()
            handlerTasks.removeAll()
            return value
        }

        if stopped.listener >= 0 {
            shutdown(stopped.listener, SHUT_RDWR)
            close(stopped.listener)
        }
        stopped.handlerTasks.forEach { $0.cancel() }
        stopped.connections.forEach { $0.close() }
        if let identity = stopped.identity {
            Self.unlinkSocketIfUnchanged(at: socketURL, identity: identity)
        }
        if stopped.lockDescriptor >= 0 {
            flock(stopped.lockDescriptor, LOCK_UN)
            close(stopped.lockDescriptor)
        }
    }

    deinit {
        stop()
    }

    private func acceptConnections(listener expectedListener: Int32) {
        while stateLock.withLock({
            listener == expectedListener && listener >= 0
        }) {
            let accepted = accept(expectedListener, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                break
            }

            let socket = ManagedSocket(descriptor: accepted)
            let acceptedConnection = stateLock.withLock { () -> Bool in
                guard listener == expectedListener,
                      connections.count < 16 else {
                    return false
                }
                connections[ObjectIdentifier(socket)] = socket
                return true
            }
            guard acceptedConnection else {
                socket.close()
                continue
            }

            DispatchQueue.global(qos: .utility).async { [weak self, socket] in
                self?.receiveRequest(from: socket)
            }
        }
    }

    private func receiveRequest(from socket: ManagedSocket) {
        do {
            try TiroCommandSocketSecurity.validatePeer(socket.descriptor)
            let data = try Self.readRequest(
                from: socket,
                timeout: requestTimeout
            )
            let request: TiroCommandRequest
            do {
                request = try JSONDecoder().decode(TiroCommandRequest.self, from: data)
                _ = try request.validated()
            } catch let error as TiroProtocolError {
                throw error
            } catch {
                throw TiroProtocolError.invalidRequest(
                    "The command request is malformed."
                )
            }

            guard let handler = stateLock.withLock({ self.handler }) else {
                socket.close()
                removeConnection(socket)
                return
            }

            let responder = TiroCommandResponder(
                request: request,
                socket: socket,
                writeTimeout: requestTimeout,
                onClose: { [weak self, weak socket] in
                    guard let socket else { return }
                    self?.removeConnection(socket)
                }
            )
            let identifier = ObjectIdentifier(socket)
            let task = Task { [weak self, socket] in
                do {
                    try await handler(request, responder)
                    await responder.finishIfNeeded()
                } catch {
                    await responder.failIfNeeded(
                        code: "internal_error",
                        message: "Tiro could not complete the command."
                    )
                }
                self?.removeConnection(socket)
            }
            let retained = stateLock.withLock { () -> Bool in
                guard connections[identifier] != nil else { return false }
                handlerTasks[identifier] = task
                return true
            }
            if !retained {
                task.cancel()
                socket.close()
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self, socket] in
                self?.monitorDisconnect(from: socket)
            }
        } catch {
            socket.close()
            removeConnection(socket)
        }
    }

    private func monitorDisconnect(from socket: ManagedSocket) {
        guard let descriptor = try? socket.duplicateDescriptor() else {
            disconnect(socket)
            return
        }
        defer { Darwin.close(descriptor) }

        while stateLock.withLock({
            connections[ObjectIdentifier(socket)] != nil
        }) {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = poll(&pollDescriptor, 1, 250)
            if result < 0, errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0 else {
                disconnect(socket)
                return
            }
            if pollDescriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 {
                disconnect(socket)
                return
            }
            if pollDescriptor.revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                let count = Darwin.read(descriptor, &byte, 1)
                if count < 0, (errno == EINTR || errno == EAGAIN) {
                    continue
                }
                // The protocol permits exactly one request per connection.
                disconnect(socket)
                return
            }
        }
    }

    private func disconnect(_ socket: ManagedSocket) {
        let task: Task<Void, Never>? = stateLock.withLock {
            let identifier = ObjectIdentifier(socket)
            guard connections.removeValue(forKey: identifier) != nil else {
                return nil
            }
            return handlerTasks.removeValue(forKey: identifier)
        }
        task?.cancel()
        socket.close()
    }

    private func removeConnection(_ socket: ManagedSocket) {
        stateLock.withLock {
            let identifier = ObjectIdentifier(socket)
            handlerTasks.removeValue(forKey: identifier)
            connections.removeValue(forKey: identifier)
        }
    }

    private static func readRequest(
        from socket: ManagedSocket,
        timeout: TimeInterval
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw TiroCommandSocketServerError.requestTimedOut
            }
            var descriptor = pollfd(
                fd: socket.descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let milliseconds = Int32(
                min(Double(Int32.max), ceil(remaining * 1_000))
            )
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                if result == 0 {
                    throw TiroCommandSocketServerError.requestTimedOut
                }
                throw TiroSocketError.systemCall("poll", errno)
            }

            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(socket.descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw TiroSocketError.systemCall("read", errno)
            }
            guard count > 0 else {
                throw TiroProtocolError.invalidRequest(
                    "The command request is incomplete."
                )
            }

            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= TiroProtocolLimits.maximumRequestBytes + 1 else {
                throw TiroProtocolError.requestTooLarge
            }
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                guard !line.isEmpty,
                      line.count <= TiroProtocolLimits.maximumRequestBytes else {
                    throw TiroProtocolError.invalidRequest(
                        "The command request is empty."
                    )
                }
                return Data(line)
            }
        }
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        let path = url.path
        let created: Bool
        if mkdir(path, 0o700) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw TiroSocketError.systemCall("mkdir", errno)
        }
        if created, chmod(path, 0o700) != 0 {
            throw TiroSocketError.systemCall("chmod", errno)
        }
        let directoryIdentity = try identity(at: url, expectedType: S_IFDIR)
        guard directoryIdentity.owner == geteuid() else {
            throw TiroCommandSocketServerError.unsafeParentDirectory
        }
        guard directoryIdentity.permissions == 0o700 else {
            throw TiroCommandSocketServerError.unsafeParentDirectory
        }
    }

    private static func acquireServerLock(for socketURL: URL) throws -> Int32 {
        let lockURL = socketURL.deletingLastPathComponent()
            .appendingPathComponent(".command-v1.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw TiroSocketError.systemCall("open", errno)
        }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw TiroSocketError.systemCall("fstat", errno)
            }
            guard status.st_uid == geteuid(),
                  status.st_mode & S_IFMT == S_IFREG else {
                throw TiroCommandSocketServerError.unsafeLockFile
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw TiroSocketError.systemCall("fchmod", errno)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK {
                    throw TiroCommandSocketServerError.alreadyRunning
                }
                throw TiroSocketError.systemCall("flock", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func removeStaleSocketIfSafe(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw TiroSocketError.systemCall("lstat", errno)
        }
        guard status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFSOCK else {
            throw TiroCommandSocketServerError.unsafeExistingSocketPath
        }
        guard unlink(url.path) == 0 else {
            throw TiroSocketError.systemCall("unlink", errno)
        }
    }

    private static func makeListener(at url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TiroSocketError.systemCall("socket", errno)
        }
        do {
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
            guard chmod(url.path, 0o600) == 0 else {
                throw TiroSocketError.systemCall("chmod", errno)
            }
            guard listen(descriptor, 16) == 0 else {
                throw TiroSocketError.systemCall("listen", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            unlink(url.path)
            throw error
        }
    }

    private static func identity(
        at url: URL,
        expectedType: mode_t
    ) throws -> FileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw TiroSocketError.systemCall("lstat", errno)
        }
        guard status.st_mode & S_IFMT == expectedType else {
            throw TiroCommandSocketServerError.unexpectedFileType
        }
        return FileIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            owner: status.st_uid,
            permissions: status.st_mode & 0o777
        )
    }

    private static func unlinkSocketIfUnchanged(
        at url: URL,
        identity expected: FileIdentity
    ) {
        guard let current = try? identity(at: url, expectedType: S_IFSOCK),
              current.device == expected.device,
              current.inode == expected.inode,
              current.owner == geteuid() else {
            return
        }
        unlink(url.path)
    }
}

public actor TiroCommandResponder {
    private let request: TiroCommandRequest
    private let socket: ManagedSocket
    private let writeTimeout: TimeInterval
    private let onClose: @Sendable () -> Void
    private var terminalSent = false
    private var messageCount = 0
    private var responseBytes = 0

    fileprivate init(
        request: TiroCommandRequest,
        socket: ManagedSocket,
        writeTimeout: TimeInterval,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.request = request
        self.socket = socket
        self.writeTimeout = writeTimeout
        self.onClose = onClose
    }

    public var hasSentTerminalMessage: Bool {
        terminalSent
    }

    public func sendEvent(
        name: String,
        fraction: Double? = nil,
        detail: String? = nil
    ) throws {
        guard !terminalSent else {
            throw TiroCommandSocketServerError.terminalAlreadySent
        }
        try send(.event(
            id: request.id,
            name: name,
            fraction: fraction,
            detail: detail
        ))
    }

    public func sendSuccess(_ result: TiroCommandResult) throws {
        try sendTerminal(.success(id: request.id, result: result))
    }

    public func sendFailure(code: String, message: String) throws {
        try sendTerminal(.failure(
            id: request.id,
            code: code,
            message: message
        ))
    }

    fileprivate func finishIfNeeded() {
        guard !terminalSent else { return }
        try? sendTerminal(.failure(
            id: request.id,
            code: "handler_incomplete",
            message: "Tiro did not complete the command."
        ))
    }

    fileprivate func failIfNeeded(code: String, message: String) {
        guard !terminalSent else { return }
        try? sendTerminal(.failure(
            id: request.id,
            code: code,
            message: message
        ))
    }

    private func sendTerminal(_ message: TiroCommandMessage) throws {
        guard !terminalSent else {
            throw TiroCommandSocketServerError.terminalAlreadySent
        }
        terminalSent = true
        defer {
            onClose()
            socket.close()
        }
        try send(message)
    }

    private func send(_ message: TiroCommandMessage) throws {
        _ = try message.validated(for: request)
        messageCount += 1
        guard messageCount <= TiroProtocolLimits.maximumMessages else {
            throw TiroProtocolError.tooManyMessages
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        guard data.count <= TiroProtocolLimits.maximumMessageBytes else {
            throw TiroProtocolError.messageTooLarge
        }
        responseBytes += data.count
        guard responseBytes <= TiroProtocolLimits.maximumResponseBytes else {
            throw TiroProtocolError.responseTooLarge
        }
        try socket.write(data, timeout: writeTimeout)
    }
}

public enum TiroCommandSocketServerError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case invalidRequestTimeout
    case requestTimedOut
    case unsafeParentDirectory
    case unsafeLockFile
    case unsafeExistingSocketPath
    case unexpectedFileType
    case terminalAlreadySent
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A Tiro command server is already running."
        case .invalidRequestTimeout:
            "The command request timeout is invalid."
        case .requestTimedOut:
            "The command client did not send a request in time."
        case .unsafeParentDirectory:
            "The command socket directory is not private to the current user."
        case .unsafeLockFile:
            "The command server lock file is unsafe."
        case .unsafeExistingSocketPath:
            "The existing command socket path cannot be safely replaced."
        case .unexpectedFileType:
            "A command transport path has an unexpected file type."
        case .terminalAlreadySent:
            "This command connection already sent its final response."
        case .connectionClosed:
            "The command connection is closed."
        }
    }
}

private struct FileIdentity {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let permissions: mode_t
}

private final class ManagedSocket: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var noSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
    }

    func duplicateDescriptor() throws -> Int32 {
        try lock.withLock {
            guard !closed else {
                throw TiroCommandSocketServerError.connectionClosed
            }
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else {
                throw TiroSocketError.systemCall("dup", errno)
            }
            return duplicate
        }
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        let writeDescriptor = try duplicateDescriptor()
        defer { Darwin.close(writeDescriptor) }

        let flags = fcntl(writeDescriptor, F_GETFL)
        guard flags >= 0,
              fcntl(writeDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TiroSocketError.systemCall("fcntl", errno)
        }

        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw TiroSocketError.timedOut
                }
                var pollDescriptor = pollfd(
                    fd: writeDescriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let milliseconds = Int32(
                    min(Double(Int32.max), ceil(remaining * 1_000))
                )
                let pollResult = poll(&pollDescriptor, 1, milliseconds)
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else {
                    if pollResult == 0 {
                        throw TiroSocketError.timedOut
                    }
                    throw TiroSocketError.systemCall("poll", errno)
                }
                guard pollDescriptor.revents & Int16(POLLNVAL | POLLERR) == 0,
                      pollDescriptor.revents & Int16(POLLOUT) != 0 else {
                    throw TiroCommandSocketServerError.connectionClosed
                }

                let count = Darwin.write(
                    writeDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, (errno == EINTR || errno == EAGAIN) {
                    continue
                } else if count < 0, (errno == EPIPE || errno == ECONNRESET) {
                    throw TiroCommandSocketServerError.connectionClosed
                } else {
                    throw TiroSocketError.systemCall("write", errno)
                }
            }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    deinit {
        close()
    }
}
