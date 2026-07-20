import Foundation

public enum TiroProtocolLimits {
    public static let version = 1
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumMessageBytes = 1_024 * 1_024
    public static let maximumResponseBytes = 4 * 1_024 * 1_024
    public static let maximumMessages = 1_024
    public static let maximumPathBytes = 4_096
    public static let maximumModelKeyBytes = 128
    public static let maximumSocketPathBytes = 103
    public static let defaultResponseTimeout: TimeInterval = 3_600
}

public enum TiroCommandName: String, Codable, Sendable {
    case status
    case models
    case transcribe
    case recordStart = "record_start"
    case recordStop = "record_stop"
    case recordCancel = "record_cancel"
}

public struct TiroCommandArguments: Codable, Equatable, Sendable {
    public let path: String?
    public let model: String?
    public let copy: Bool?
    public let saveHistory: Bool?
    public let diarize: Bool?
    public let session: String?

    public init(
        path: String? = nil,
        model: String? = nil,
        copy: Bool? = nil,
        saveHistory: Bool? = nil,
        diarize: Bool? = nil,
        session: String? = nil
    ) {
        self.path = path
        self.model = model
        self.copy = copy
        self.saveHistory = saveHistory
        self.diarize = diarize
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case model
        case copy
        case saveHistory = "save_history"
        case diarize
        case session
    }
}

public struct TiroCommandRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let command: TiroCommandName
    public let arguments: TiroCommandArguments?

    public init(
        id: UUID = UUID(),
        command: TiroCommandName,
        arguments: TiroCommandArguments? = nil
    ) {
        version = TiroProtocolLimits.version
        self.id = id.uuidString.lowercased()
        self.command = command
        self.arguments = arguments
    }

    public static func status(id: UUID = UUID()) -> TiroCommandRequest {
        TiroCommandRequest(id: id, command: .status)
    }

    public static func models(id: UUID = UUID()) -> TiroCommandRequest {
        TiroCommandRequest(id: id, command: .models)
    }

    public static func transcribe(
        path: String,
        model: String?,
        copy: Bool,
        saveHistory: Bool,
        diarize: Bool = false,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .transcribe,
            arguments: TiroCommandArguments(
                path: path,
                model: model,
                copy: copy,
                saveHistory: saveHistory,
                diarize: diarize
            )
        )
    }

    public static func recordStart(
        model: String?,
        saveHistory: Bool,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .recordStart,
            arguments: TiroCommandArguments(model: model, saveHistory: saveHistory)
        )
    }

    public static func recordStop(
        session: String,
        copy: Bool,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .recordStop,
            arguments: TiroCommandArguments(copy: copy, session: session)
        )
    }

    public static func recordCancel(
        session: String,
        id: UUID = UUID()
    ) -> TiroCommandRequest {
        TiroCommandRequest(
            id: id,
            command: .recordCancel,
            arguments: TiroCommandArguments(session: session)
        )
    }

    public func validated() throws -> TiroCommandRequest {
        guard version == TiroProtocolLimits.version else {
            throw TiroProtocolError.unsupportedVersion(version)
        }
        guard UUID(uuidString: id) != nil else {
            throw TiroProtocolError.invalidRequest("The request ID is invalid.")
        }
        switch command {
        case .status, .models:
            guard arguments == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The status command does not accept arguments."
                )
            }
        case .transcribe:
            guard let arguments, let path = arguments.path, !path.isEmpty else {
                throw TiroProtocolError.invalidRequest(
                    "The transcribe command requires a file path."
                )
            }
            guard path.utf8.count <= TiroProtocolLimits.maximumPathBytes else {
                throw TiroProtocolError.invalidRequest("The file path is too long.")
            }
            if let model = arguments.model {
                guard !model.isEmpty,
                      model.utf8.count <= TiroProtocolLimits.maximumModelKeyBytes else {
                    throw TiroProtocolError.invalidRequest("The model key is invalid.")
                }
            }
        case .recordStart:
            guard let arguments,
                  arguments.path == nil,
                  arguments.session == nil,
                  arguments.diarize == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The record start command has invalid arguments."
                )
            }
            try Self.validateModel(arguments.model)
        case .recordStop:
            guard arguments?.diarize == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The record stop command has invalid arguments."
                )
            }
            try Self.validateSession(arguments?.session)
        case .recordCancel:
            guard arguments?.diarize == nil else {
                throw TiroProtocolError.invalidRequest(
                    "The record cancel command has invalid arguments."
                )
            }
            try Self.validateSession(arguments?.session)
        }
        return self
    }

    private static func validateModel(_ model: String?) throws {
        guard let model else { return }
        guard !model.isEmpty,
              model.utf8.count <= TiroProtocolLimits.maximumModelKeyBytes else {
            throw TiroProtocolError.invalidRequest("The model key is invalid.")
        }
    }

    private static func validateSession(_ session: String?) throws {
        guard let session, UUID(uuidString: session) != nil else {
            throw TiroProtocolError.invalidRequest("The recording session is invalid.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case id
        case command
        case arguments
    }
}

public enum TiroCommandMessageType: String, Codable, Sendable {
    case event
    case success
    case failure
}

public struct TiroCommandEvent: Codable, Equatable, Sendable {
    public let name: String
    public let fraction: Double?
    public let detail: String?

    public init(name: String, fraction: Double? = nil, detail: String? = nil) {
        self.name = name
        self.fraction = fraction
        self.detail = detail
    }
}

public struct TiroCommandResult: Codable, Equatable, Sendable {
    public let kind: String
    public let text: String?
    public let model: String?
    public let historyID: String?
    public let transcriptionSeconds: Double?
    public let state: String?
    public let selectedModel: String?
    public let session: String?
    public let segments: [TiroCommandSegment]?
    public let models: [TiroCommandModel]?

    public init(
        kind: String,
        text: String? = nil,
        model: String? = nil,
        historyID: String? = nil,
        transcriptionSeconds: Double? = nil,
        state: String? = nil,
        selectedModel: String? = nil,
        session: String? = nil,
        segments: [TiroCommandSegment]? = nil,
        models: [TiroCommandModel]? = nil
    ) {
        self.kind = kind
        self.text = text
        self.model = model
        self.historyID = historyID
        self.transcriptionSeconds = transcriptionSeconds
        self.state = state
        self.selectedModel = selectedModel
        self.session = session
        self.segments = segments
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case model
        case historyID = "history_id"
        case transcriptionSeconds = "transcription_seconds"
        case state
        case selectedModel = "selected_model"
        case session
        case segments
        case models
    }
}

public struct TiroCommandModel: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let installed: Bool
    public let transcription: Bool

    public init(key: String, name: String, installed: Bool, transcription: Bool) {
        self.key = key
        self.name = name
        self.installed = installed
        self.transcription = transcription
    }
}

public struct TiroCommandSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: Double
    public let endTime: Double
    public let speakerID: String?

    public init(
        text: String,
        startTime: Double,
        endTime: Double,
        speakerID: String? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case startTime = "start"
        case endTime = "end"
        case speakerID = "speaker_id"
    }
}

public struct TiroCommandFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TiroCommandMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let type: TiroCommandMessageType
    public let event: TiroCommandEvent?
    public let result: TiroCommandResult?
    public let error: TiroCommandFailure?

    public init(
        version: Int = TiroProtocolLimits.version,
        id: String,
        type: TiroCommandMessageType,
        event: TiroCommandEvent? = nil,
        result: TiroCommandResult? = nil,
        error: TiroCommandFailure? = nil
    ) {
        self.version = version
        self.id = id
        self.type = type
        self.event = event
        self.result = result
        self.error = error
    }

    public static func event(
        id: String,
        name: String,
        fraction: Double? = nil,
        detail: String? = nil
    ) -> TiroCommandMessage {
        TiroCommandMessage(
            id: id,
            type: .event,
            event: TiroCommandEvent(name: name, fraction: fraction, detail: detail)
        )
    }

    public static func success(
        id: String,
        result: TiroCommandResult
    ) -> TiroCommandMessage {
        TiroCommandMessage(id: id, type: .success, result: result)
    }

    public static func failure(
        id: String,
        code: String,
        message: String
    ) -> TiroCommandMessage {
        TiroCommandMessage(
            id: id,
            type: .failure,
            error: TiroCommandFailure(code: code, message: message)
        )
    }

    public func validated(for request: TiroCommandRequest) throws -> TiroCommandMessage {
        guard version == TiroProtocolLimits.version else {
            throw TiroProtocolError.unsupportedVersion(version)
        }
        guard id == request.id else {
            throw TiroProtocolError.unexpectedResponse(
                "The response ID does not match the request."
            )
        }
        switch type {
        case .event:
            guard let event, result == nil, error == nil, !event.name.isEmpty else {
                throw TiroProtocolError.unexpectedResponse("The event response is malformed.")
            }
            if let fraction = event.fraction,
               (!fraction.isFinite || !(0...1).contains(fraction)) {
                throw TiroProtocolError.unexpectedResponse(
                    "The event progress value is invalid."
                )
            }
        case .success:
            guard result != nil, event == nil, error == nil else {
                throw TiroProtocolError.unexpectedResponse(
                    "The success response is malformed."
                )
            }
        case .failure:
            guard let error, event == nil, result == nil,
                  !error.code.isEmpty, !error.message.isEmpty else {
                throw TiroProtocolError.unexpectedResponse(
                    "The failure response is malformed."
                )
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case id
        case type
        case event
        case result
        case error
    }
}

public enum TiroProtocolError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidRequest(String)
    case unexpectedResponse(String)
    case requestTooLarge
    case messageTooLarge
    case responseTooLarge
    case tooManyMessages
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Tiro command protocol version \(version) is not supported."
        case .invalidRequest(let message), .unexpectedResponse(let message):
            message
        case .requestTooLarge:
            "The Tiro command request is too large."
        case .messageTooLarge:
            "A response from Tiro exceeded the message limit."
        case .responseTooLarge:
            "The complete response from Tiro exceeded the size limit."
        case .tooManyMessages:
            "Tiro sent too many response messages."
        case .incompleteResponse:
            "Tiro closed the connection without a final response."
        }
    }
}
