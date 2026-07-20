import Darwin
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

public struct TranscriptWord: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let speakerID: String?
    public let words: [TranscriptWord]

    public init(
        text: String,
        startSeconds: Double,
        endSeconds: Double,
        speakerID: String? = nil,
        words: [TranscriptWord] = []
    ) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerID = speakerID
        self.words = words
    }
}

public struct RawTranscript: Codable, Equatable, Sendable {
    public let text: String
    public let model: RecognitionModel
    public let audioSeconds: Double
    public let transcriptionSeconds: Double
    public let timesFasterThanRealtime: Double
    public let segments: [TranscriptSegment]

    public init(
        text: String,
        model: RecognitionModel,
        audioSeconds: Double,
        transcriptionSeconds: Double,
        timesFasterThanRealtime: Double,
        segments: [TranscriptSegment] = []
    ) {
        self.text = text
        self.model = model
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.timesFasterThanRealtime = timesFasterThanRealtime
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case model
        case audioSeconds
        case transcriptionSeconds
        case timesFasterThanRealtime
        case segments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        model = try container.decode(RecognitionModel.self, forKey: .model)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        transcriptionSeconds = try container.decode(Double.self, forKey: .transcriptionSeconds)
        timesFasterThanRealtime = try container.decode(
            Double.self,
            forKey: .timesFasterThanRealtime
        )
        segments = try container.decodeIfPresent(
            [TranscriptSegment].self,
            forKey: .segments
        ) ?? []
    }
}

public enum CoreMLModelActivity: String, Codable, Sendable {
    case idle
    case cleaning
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

final class ModelDirectoryLease: @unchecked Sendable {
    private static let processLock = NSLock()
    private static var activeRoots: Set<String> = []

    private var descriptor: Int32
    private let rootPath: String

    private init(descriptor: Int32, rootPath: String) {
        self.descriptor = descriptor
        self.rootPath = rootPath
    }

    static func acquire(at root: URL) -> ModelDirectoryLease? {
        let rootPath = root.standardizedFileURL.path
        let reserved = processLock.withLock {
            activeRoots.insert(rootPath).inserted
        }
        guard reserved else { return nil }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        } catch {
            processLock.withLock { _ = activeRoots.remove(rootPath) }
            return nil
        }
        let lockURL = root.appendingPathComponent(".tiro-operation.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            processLock.withLock { _ = activeRoots.remove(rootPath) }
            return nil
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            close(descriptor)
            processLock.withLock { _ = activeRoots.remove(rootPath) }
            return nil
        }
        return ModelDirectoryLease(descriptor: descriptor, rootPath: rootPath)
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.lockf(descriptor, F_ULOCK, 0)
        close(descriptor)
        descriptor = -1
        Self.processLock.withLock {
            _ = Self.activeRoots.remove(rootPath)
        }
    }

    deinit {
        release()
    }
}

func modelDirectoryRootIsSafe(_ root: URL) -> Bool {
    let lexical = root.standardizedFileURL.path
    var resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
    if resolved.hasPrefix("/private/var/") || resolved.hasPrefix("/private/tmp/") {
        resolved.removeFirst("/private".count)
    }
    return lexical == resolved
}
