import Foundation

public enum RecognitionModel: String, Codable, Sendable {
    case parakeetCompactCoreML = "parakeet-tdt-ctc-110m-coreml"
}

public struct RecognitionRequest: Sendable {
    public let audioURL: URL
    public let model: RecognitionModel

    public init(audioURL: URL, model: RecognitionModel) {
        self.audioURL = audioURL
        self.model = model
    }
}

public struct RawTranscript: Codable, Sendable {
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

public struct RecognitionPreparation: Codable, Sendable {
    public let downloadSeconds: Double
    public let loadSeconds: Double

    public init(downloadSeconds: Double, loadSeconds: Double) {
        self.downloadSeconds = downloadSeconds
        self.loadSeconds = loadSeconds
    }
}

public protocol RecognitionEngine: Sendable {
    func prepare(
        model: RecognitionModel,
        allowDownload: Bool
    ) async throws -> RecognitionPreparation
    func recognize(_ request: RecognitionRequest) async throws -> RawTranscript
}
