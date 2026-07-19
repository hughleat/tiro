import Foundation

public enum RecognitionModel: String, Codable, Sendable {
    case appleSpeech = "apple-speech"
    case parakeetCompactCoreML = "parakeet-tdt-ctc-110m-coreml"
    case parakeetV2CoreML = "parakeet-tdt-0.6b-v2-coreml"
    case parakeetV3CoreML = "parakeet-tdt-0.6b-v3-coreml"
    case whisperTinyEnglishCoreML = "whisper-tiny-english-coreml"
    case whisperBaseEnglishCoreML = "whisper-base-english-coreml"
    case whisperSmallEnglishCoreML = "whisper-small-english-coreml"
    case whisperTinyCoreML = "whisper-tiny-coreml"
    case whisperBaseCoreML = "whisper-base-coreml"
    case whisperSmallCoreML = "whisper-small-coreml"
    case whisperDistilLargeV3CoreML = "whisper-distil-large-v3-coreml"
    case whisperLargeV3CoreML = "whisper-large-v3-coreml"
    case whisperTurboCoreML = "whisper-large-v3-turbo-coreml"
}

public enum ParakeetModel: String, CaseIterable, Codable, Sendable {
    case compact
    case v2
    case v3

    public var recognitionModel: RecognitionModel {
        switch self {
        case .compact: .parakeetCompactCoreML
        case .v2: .parakeetV2CoreML
        case .v3: .parakeetV3CoreML
        }
    }

    public var directoryName: String {
        switch self {
        case .compact: "parakeet-tdt-ctc-110m"
        case .v2: "parakeet-tdt-0.6b-v2"
        case .v3: "parakeet-tdt-0.6b-v3"
        }
    }
}

public struct RawTranscript: Codable, Equatable, Sendable {
    public let text: String
    public let model: RecognitionModel
    public let audioSeconds: Double
    public let transcriptionSeconds: Double
    public let timesFasterThanRealtime: Double

    public init(
        text: String,
        model: RecognitionModel,
        audioSeconds: Double,
        transcriptionSeconds: Double,
        timesFasterThanRealtime: Double
    ) {
        self.text = text
        self.model = model
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.timesFasterThanRealtime = timesFasterThanRealtime
    }
}

public enum CoreMLModelActivity: String, Codable, Sendable {
    case idle
    case downloading
    case loading
    case transcribing
    case deleting
}

public struct CoreMLModelStatus: Equatable, Sendable {
    public let directory: URL
    public let installed: Bool
    public let loaded: Bool
    public let sizeBytes: Int64
    public let activity: CoreMLModelActivity
    public let downloadProgress: Double?
    public let lastError: String?

    public init(
        directory: URL,
        installed: Bool,
        loaded: Bool,
        sizeBytes: Int64,
        activity: CoreMLModelActivity,
        downloadProgress: Double?,
        lastError: String?
    ) {
        self.directory = directory
        self.installed = installed
        self.loaded = loaded
        self.sizeBytes = sizeBytes
        self.activity = activity
        self.downloadProgress = downloadProgress
        self.lastError = lastError
    }
}

public protocol RecognitionEngine: Sendable {
    func preload() async throws
    func transcribe(_ audioURL: URL) async throws -> RawTranscript
}
