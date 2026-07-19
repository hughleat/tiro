import Foundation

public enum RecognitionModel: String, Codable, Sendable {
    case parakeetCompactCoreML = "parakeet-tdt-ctc-110m-coreml"
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
