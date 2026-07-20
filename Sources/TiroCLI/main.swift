import Darwin
import Foundation
import TiroIPC

enum CLIExitCode: Int32 {
    case success = 0
    case usage = 64
    case unavailable = 69
    case software = 70
    case temporaryFailure = 75
    case permission = 77
    case configuration = 78
}

enum CLIExecutionError: Error, LocalizedError {
    case appNotFound
    case appLaunchFailed
    case inputFileUnavailable(String)
    case malformedResult

    var errorDescription: String? {
        switch self {
        case .appNotFound:
            "Tiro.app could not be found. Install Tiro in Applications."
        case .appLaunchFailed:
            "Tiro could not be launched."
        case .inputFileUnavailable(let path):
            "The input file is not readable: \(path)"
        case .malformedResult:
            "Tiro returned an unsupported command result."
        }
    }
}

enum TiroCLI {
    static func run() -> Int32 {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let requestedJSON = rawArguments.contains("--json")
        let invocation: CLIInvocation
        do {
            invocation = try CLIArguments.parse(rawArguments)
        } catch {
            writeFailure(
                code: "usage",
                message: error.localizedDescription + "\n\n" + CLIArguments.usage,
                format: requestedJSON ? .json : .text
            )
            return CLIExitCode.usage.rawValue
        }

        switch invocation {
        case .help:
            write(Data((CLIArguments.usage + "\n").utf8), to: .standardOutput)
            return CLIExitCode.success.rawValue
        case .version:
            let appURL = TiroAppLocator.appURL()
            write(Data((TiroAppLocator.version(appURL: appURL) + "\n").utf8), to: .standardOutput)
            return CLIExitCode.success.rawValue
        case .status, .models, .transcribe, .recordStart, .recordStop, .recordCancel:
            break
        }

        do {
            let request = try makeRequest(invocation)
            let response = try sendLaunchingAppIfNeeded(request)
            if response.type == .failure, let failure = response.error {
                writeFailure(
                    code: failure.code,
                    message: failure.message,
                    format: invocation.format
                )
                return exitCode(for: failure.code).rawValue
            }
            let output = try CLIOutput.success(response, format: invocation.format)
            write(output, to: .standardOutput)
            return CLIExitCode.success.rawValue
        } catch {
            let code = exitCode(for: error)
            writeFailure(
                code: errorCode(for: error),
                message: error.localizedDescription,
                format: invocation.format
            )
            return code.rawValue
        }
    }

    private static func makeRequest(_ invocation: CLIInvocation) throws -> TiroCommandRequest {
        switch invocation {
        case .status:
            return .status()
        case .models:
            return .models()
        case .transcribe(let path, let model, let copy, let saveHistory, let diarize, _):
            var isDirectory: ObjCBool = false
            guard FileManager.default.isReadableFile(atPath: path),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw CLIExecutionError.inputFileUnavailable(path)
            }
            return .transcribe(
                path: path,
                model: model,
                copy: copy,
                saveHistory: saveHistory,
                diarize: diarize
            )
        case .recordStart(let model, let saveHistory, _):
            return .recordStart(model: model, saveHistory: saveHistory)
        case .recordStop(let session, let copy, _):
            return .recordStop(session: session, copy: copy)
        case .recordCancel(let session, _):
            return .recordCancel(session: session)
        case .help, .version:
            preconditionFailure("This invocation does not create a request.")
        }
    }

    private static func sendLaunchingAppIfNeeded(
        _ request: TiroCommandRequest
    ) throws -> TiroCommandMessage {
        let socketURL = TiroCommandSocketPath.defaultURL()
        let client = TiroCommandSocketClient(socketURL: socketURL)
        do {
            return try client.send(request)
        } catch let error as TiroSocketError where error.isRetryableConnectionFailure {
            guard let appURL = TiroAppLocator.appURL() else {
                throw CLIExecutionError.appNotFound
            }
            try TiroAppLauncher.launch(appURL)
            let deadline = Date().addingTimeInterval(5)
            var lastError: Error = error
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                do {
                    return try client.send(request)
                } catch let retry as TiroSocketError where retry.isRetryableConnectionFailure {
                    lastError = retry
                }
            }
            throw lastError
        }
    }

    private static func exitCode(for serverCode: String) -> CLIExitCode {
        switch serverCode {
        case "busy": .temporaryFailure
        case "permission_denied": .permission
        case "setup_required", "model_missing": .configuration
        default: .software
        }
    }

    private static func exitCode(for error: Error) -> CLIExitCode {
        if let socketError = error as? TiroSocketError {
            switch socketError {
            case .connectionFailed:
                return .unavailable
            case .peerUIDMismatch:
                return .permission
            case .timedOut:
                return .temporaryFailure
            default:
                return .software
            }
        }
        if error is CLIExecutionError {
            switch error {
            case CLIExecutionError.appNotFound, CLIExecutionError.appLaunchFailed:
                return .unavailable
            case CLIExecutionError.inputFileUnavailable:
                return .configuration
            default:
                return .software
            }
        }
        return .software
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case CLIExecutionError.appNotFound, CLIExecutionError.appLaunchFailed:
            "app_unavailable"
        case CLIExecutionError.inputFileUnavailable:
            "input_unavailable"
        case let socket as TiroSocketError where socket == .timedOut:
            "timeout"
        case let socket as TiroSocketError:
            if case .peerUIDMismatch = socket { "permission_denied" } else { "transport_error" }
        case is TiroProtocolError:
            "protocol_error"
        default:
            "internal_error"
        }
    }

    private static func writeFailure(
        code: String,
        message: String,
        format: CLIOutputFormat
    ) {
        do {
            let output = try CLIOutput.failure(code: code, message: message, format: format)
            write(output.standardOutput, to: .standardOutput)
            write(output.standardError, to: .standardError)
        } catch {
            write(Data(("tiro: \(message)\n").utf8), to: .standardError)
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) {
        guard !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // There is nowhere reliable to report a failed standard stream.
        }
    }
}

Darwin.exit(TiroCLI.run())
