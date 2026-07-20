import Foundation
import TiroIPC

enum CLIOutputFormat {
    case text
    case json
}

enum CLIInvocation: Equatable {
    case help
    case version
    case status(format: CLIOutputFormat)
    case models(format: CLIOutputFormat)
    case transcribe(
        path: String,
        model: String?,
        copy: Bool,
        saveHistory: Bool,
        diarize: Bool,
        format: CLIOutputFormat
    )
    case recordForeground(
        model: String?,
        copy: Bool,
        saveHistory: Bool,
        format: CLIOutputFormat
    )
    case recordStart(model: String?, saveHistory: Bool, format: CLIOutputFormat)
    case recordStop(session: String, copy: Bool, format: CLIOutputFormat)
    case recordCancel(session: String, format: CLIOutputFormat)

    var format: CLIOutputFormat {
        switch self {
        case .status(let format), .models(let format), .transcribe(_, _, _, _, _, let format),
             .recordForeground(_, _, _, let format), .recordStart(_, _, let format),
             .recordStop(_, _, let format),
             .recordCancel(_, let format):
            format
        case .help, .version:
            .text
        }
    }
}

enum CLIArgumentError: Error, Equatable, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

enum CLIArguments {
    static let usage = """
    usage:
      tiro transcribe FILE [--model KEY] [--diarize] [--copy] [--no-history] [--json]
      tiro diarize FILE [--model KEY] [--copy] [--no-history] [--json]
      tiro record [--model KEY] [--copy] [--no-history] [--json]
      tiro record start [--model KEY] [--no-history] [--json]
      tiro record stop SESSION [--copy] [--json]
      tiro record cancel SESSION [--json]
      tiro status [--json]
      tiro models [--json]
      tiro --version
    """

    static func parse(
        _ arguments: [String],
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) throws -> CLIInvocation {
        guard let command = arguments.first else { return .help }
        switch command {
        case "-h", "--help", "help":
            guard arguments.count == 1 else {
                throw CLIArgumentError.message("The help command takes no arguments.")
            }
            return .help
        case "-V", "--version":
            guard arguments.count == 1 else {
                throw CLIArgumentError.message("The version command takes no arguments.")
            }
            return .version
        case "status":
            var format = CLIOutputFormat.text
            for argument in arguments.dropFirst() {
                guard argument == "--json" else {
                    throw CLIArgumentError.message("Unknown status option: \(argument)")
                }
                format = .json
            }
            return .status(format: format)
        case "models":
            var format = CLIOutputFormat.text
            for argument in arguments.dropFirst() {
                guard argument == "--json" else {
                    throw CLIArgumentError.message("Unknown models option: \(argument)")
                }
                format = .json
            }
            return .models(format: format)
        case "transcribe":
            return try parseTranscribe(
                Array(arguments.dropFirst()),
                currentDirectory: currentDirectory,
                diarizeByDefault: false
            )
        case "diarize":
            return try parseTranscribe(
                Array(arguments.dropFirst()),
                currentDirectory: currentDirectory,
                diarizeByDefault: true
            )
        case "record":
            return try parseRecord(Array(arguments.dropFirst()))
        default:
            throw CLIArgumentError.message("Unknown command: \(command)")
        }
    }

    private static func parseTranscribe(
        _ arguments: [String],
        currentDirectory: URL,
        diarizeByDefault: Bool
    ) throws -> CLIInvocation {
        var path: String?
        var model: String?
        var copy = false
        var saveHistory = true
        var diarize = diarizeByDefault
        var format = CLIOutputFormat.text
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--copy":
                copy = true
            case "--no-history":
                saveHistory = false
            case "--diarize":
                diarize = true
            case "--json":
                format = .json
            case "--model":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    throw CLIArgumentError.message("--model requires a model key.")
                }
                guard model == nil else {
                    throw CLIArgumentError.message("--model may only be supplied once.")
                }
                model = arguments[index]
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIArgumentError.message(
                        "Unknown transcribe option: \(argument)"
                    )
                }
                guard path == nil else {
                    throw CLIArgumentError.message(
                        "The transcribe command accepts one file."
                    )
                }
                path = (argument.hasPrefix("/")
                    ? URL(fileURLWithPath: argument)
                    : currentDirectory.appendingPathComponent(argument))
                    .standardizedFileURL.path
            }
            index += 1
        }

        guard let path else {
            throw CLIArgumentError.message("The transcribe command requires a file.")
        }
        guard path.utf8.count <= TiroProtocolLimits.maximumPathBytes else {
            throw CLIArgumentError.message("The file path is too long.")
        }
        if let model, model.utf8.count > TiroProtocolLimits.maximumModelKeyBytes {
            throw CLIArgumentError.message("The model key is too long.")
        }
        return .transcribe(
            path: path,
            model: model,
            copy: copy,
            saveHistory: saveHistory,
            diarize: diarize,
            format: format
        )
    }

    private static func parseRecord(_ arguments: [String]) throws -> CLIInvocation {
        guard let action = arguments.first, !action.hasPrefix("-") else {
            return try parseForegroundRecord(arguments)
        }
        switch action {
        case "start":
            var model: String?
            var saveHistory = true
            var format = CLIOutputFormat.text
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--no-history": saveHistory = false
                case "--json": format = .json
                case "--model":
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                        throw CLIArgumentError.message("--model requires a model key.")
                    }
                    guard model == nil else {
                        throw CLIArgumentError.message("--model may only be supplied once.")
                    }
                    model = arguments[index]
                default:
                    throw CLIArgumentError.message(
                        "Unknown record start option: \(arguments[index])"
                    )
                }
                index += 1
            }
            return .recordStart(model: model, saveHistory: saveHistory, format: format)
        case "stop":
            return try parseRecordingEnd(Array(arguments.dropFirst()), cancel: false)
        case "cancel":
            return try parseRecordingEnd(Array(arguments.dropFirst()), cancel: true)
        default:
            throw CLIArgumentError.message("Unknown record action: \(action)")
        }
    }

    private static func parseForegroundRecord(
        _ arguments: [String]
    ) throws -> CLIInvocation {
        var model: String?
        var copy = false
        var saveHistory = true
        var format = CLIOutputFormat.text
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--copy": copy = true
            case "--no-history": saveHistory = false
            case "--json": format = .json
            case "--model":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    throw CLIArgumentError.message("--model requires a model key.")
                }
                guard model == nil else {
                    throw CLIArgumentError.message("--model may only be supplied once.")
                }
                model = arguments[index]
            default:
                throw CLIArgumentError.message(
                    "Unknown record option: \(arguments[index])"
                )
            }
            index += 1
        }

        return .recordForeground(
            model: model,
            copy: copy,
            saveHistory: saveHistory,
            format: format
        )
    }

    private static func parseRecordingEnd(
        _ arguments: [String],
        cancel: Bool
    ) throws -> CLIInvocation {
        var session: String?
        var copy = false
        var format = CLIOutputFormat.text
        for argument in arguments {
            switch argument {
            case "--copy" where !cancel: copy = true
            case "--json": format = .json
            default:
                guard !argument.hasPrefix("-"), session == nil else {
                    throw CLIArgumentError.message("Invalid record command argument: \(argument)")
                }
                session = argument
            }
        }
        guard let session, UUID(uuidString: session) != nil else {
            throw CLIArgumentError.message("The record command requires a valid session ID.")
        }
        return cancel
            ? .recordCancel(session: session, format: format)
            : .recordStop(session: session, copy: copy, format: format)
    }
}
