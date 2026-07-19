import CoreML
import FluidAudio
import Foundation

public enum CoreMLParakeetError: LocalizedError {
    case modelNotInstalled(URL)
    case modelNotPrepared
    case unsupportedModel(RecognitionModel)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let directory):
            return "The Core ML Compact model is not installed at \(directory.path). Run the probe with --download once."
        case .modelNotPrepared:
            return "Prepare the Core ML engine before transcribing."
        case .unsupportedModel(let model):
            return "Unsupported Core ML model: \(model.rawValue)"
        }
    }
}

public protocol CoreMLModelAccess: Sendable {
    func compactModelExists(at directory: URL) async -> Bool
    func downloadCompactModel(to directory: URL) async throws
    func loadCompactModelOffline(
        from directory: URL,
        configuration: MLModelConfiguration
    ) async throws -> AsrModels
}

public struct FluidAudioModelAccess: CoreMLModelAccess {
    public init() {}

    public func compactModelExists(at directory: URL) async -> Bool {
        AsrModels.modelsExist(at: directory, version: .tdtCtc110m)
    }

    public func downloadCompactModel(to directory: URL) async throws {
        _ = try await Self.withNetworkAccess {
            try await AsrModels.download(to: directory, version: .tdtCtc110m)
        }
    }

    public func loadCompactModelOffline(
        from directory: URL,
        configuration: MLModelConfiguration
    ) async throws -> AsrModels {
        ModelHub.offlineMode = true
        return try await AsrModels.load(
            from: directory,
            configuration: configuration,
            version: .tdtCtc110m
        )
    }

    static func withNetworkAccess<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        return try await operation()
    }
}

public actor CoreMLParakeetEngine: RecognitionEngine {
    public let modelDirectory: URL

    private let modelAccess: any CoreMLModelAccess
    private var manager: AsrManager?

    public init(
        modelDirectory: URL,
        modelAccess: any CoreMLModelAccess = FluidAudioModelAccess()
    ) {
        self.modelDirectory = modelDirectory.standardizedFileURL
        self.modelAccess = modelAccess
    }

    public func prepare(
        model: RecognitionModel,
        allowDownload: Bool
    ) async throws -> RecognitionPreparation {
        guard model == .parakeetCompactCoreML else {
            throw CoreMLParakeetError.unsupportedModel(model)
        }

        var downloadSeconds = 0.0
        if allowDownload {
            let downloadStart = ContinuousClock.now
            try await modelAccess.downloadCompactModel(to: modelDirectory)
            downloadSeconds = Self.seconds(since: downloadStart)
        }

        guard await modelAccess.compactModelExists(at: modelDirectory) else {
            throw CoreMLParakeetError.modelNotInstalled(modelDirectory)
        }

        let loadStart = ContinuousClock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let models = try await modelAccess.loadCompactModelOffline(
            from: modelDirectory,
            configuration: configuration
        )
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        return RecognitionPreparation(
            downloadSeconds: downloadSeconds,
            loadSeconds: Self.seconds(since: loadStart)
        )
    }

    public func recognize(_ request: RecognitionRequest) async throws -> RawTranscript {
        guard request.model == .parakeetCompactCoreML else {
            throw CoreMLParakeetError.unsupportedModel(request.model)
        }
        guard let manager else {
            throw CoreMLParakeetError.modelNotPrepared
        }

        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        let result = try await manager.transcribe(
            request.audioURL,
            decoderState: &decoderState
        )
        return RawTranscript(
            text: result.text,
            model: request.model,
            audioSeconds: result.duration,
            transcriptionSeconds: result.processingTime,
            timesFasterThanRealtime: Double(result.rtfx)
        )
    }

    private nonisolated static func seconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
