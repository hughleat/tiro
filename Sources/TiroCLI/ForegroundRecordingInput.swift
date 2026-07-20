import Darwin
import Dispatch
import Foundation
import TiroIPC

enum ForegroundRecordingEnd: Equatable {
    case finish
    case cancel
    case leaseEnded
    case inputFailure(Int32)
}

enum ForegroundRecordingLeaseSnapshot {
    case pending
    case started(String)
    case completed(TiroCommandMessage)
    case failed(Error)
}

final class ForegroundRecordingLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var session: String?
    private var completion: Result<TiroCommandMessage, Error>?

    func receive(_ event: TiroCommandEvent) {
        guard event.name == "recording",
              let detail = event.detail,
              UUID(uuidString: detail) != nil else {
            return
        }
        lock.withLock {
            session = detail
        }
    }

    func complete(_ result: Result<TiroCommandMessage, Error>) {
        lock.withLock {
            completion = result
        }
    }

    var snapshot: ForegroundRecordingLeaseSnapshot {
        lock.withLock {
            if let completion {
                switch completion {
                case .success(let message): return .completed(message)
                case .failure(let error): return .failed(error)
                }
            }
            if let session {
                return .started(session)
            }
            return .pending
        }
    }

    var isComplete: Bool {
        lock.withLock { completion != nil }
    }
}

final class ForegroundRecordingInput: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var interruptSource: DispatchSourceSignal?

    init(monitorInterrupts: Bool = true) {
        guard monitorInterrupts else { return }
        Darwin.signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            self?.receiveInterrupt()
        }
        interruptSource = source
        source.resume()
    }

    deinit {
        stop()
    }

    func wait(
        inputDescriptor: Int32 = STDIN_FILENO,
        operationEnded: () -> Bool = { false }
    ) -> ForegroundRecordingEnd {
        var descriptor = pollfd(
            fd: inputDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )

        while true {
            if wasInterrupted {
                return .cancel
            }
            if operationEnded() {
                return .leaseEnded
            }

            descriptor.revents = 0
            let result = Darwin.poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                return .inputFailure(errno)
            }
            if result == 0 { continue }

            if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                return .inputFailure(EIO)
            }
            if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                var byte: UInt8 = 0
                let count = Darwin.read(inputDescriptor, &byte, 1)
                if wasInterrupted {
                    return .cancel
                }
                if count == 0 {
                    return .finish
                }
                if count > 0, byte == 0x04 {
                    return .finish
                }
                if count < 0, errno != EINTR, errno != EAGAIN {
                    return .inputFailure(errno)
                }
            }
        }
    }

    func stop() {
        let source = lock.withLock { () -> DispatchSourceSignal? in
            let source = interruptSource
            interruptSource = nil
            return source
        }
        source?.cancel()
        if source != nil {
            Darwin.signal(SIGINT, SIG_DFL)
        }
    }

    func receiveInterrupt() {
        lock.withLock {
            interrupted = true
        }
    }

    var wasInterrupted: Bool {
        lock.withLock { interrupted }
    }
}
