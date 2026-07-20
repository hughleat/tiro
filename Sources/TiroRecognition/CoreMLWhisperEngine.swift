import CoreML
import Foundation
import WhisperKit

public enum WhisperModel: String, CaseIterable, Codable, Sendable {
    case tinyEnglish = "openai_whisper-tiny.en"
    case baseEnglish = "openai_whisper-base.en"
    case smallEnglish = "openai_whisper-small.en"
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case distilLargeV3 = "distil-whisper_distil-large-v3_594MB"
    case largeV3 = "large-v3-v20240930_626MB"
    case turbo = "large-v3-v20240930_turbo_632MB"

    public var spec: WhisperModelSpec {
        switch self {
        case .tinyEnglish, .baseEnglish, .smallEnglish:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: rawValue
            )
        case .tiny:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: "openai_whisper-tiny"
            )
        case .base:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: "openai_whisper-base"
            )
        case .small:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: "openai_whisper-small"
            )
        case .distilLargeV3:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: rawValue
            )
        case .largeV3:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: "openai_whisper-large-v3-v20240930_626MB"
            )
        case .turbo:
            WhisperModelSpec(
                model: self,
                variant: rawValue,
                directoryName: "openai_whisper-large-v3-v20240930_turbo_632MB"
            )
        }
    }

    public var recognitionModel: RecognitionModel {
        switch self {
        case .tinyEnglish: .whisperTinyEnglishCoreML
        case .baseEnglish: .whisperBaseEnglishCoreML
        case .smallEnglish: .whisperSmallEnglishCoreML
        case .tiny: .whisperTinyCoreML
        case .base: .whisperBaseCoreML
        case .small: .whisperSmallCoreML
        case .distilLargeV3: .whisperDistilLargeV3CoreML
        case .largeV3: .whisperLargeV3CoreML
        case .turbo: .whisperTurboCoreML
        }
    }

    public var isSupportedOnCurrentDevice: Bool {
        WhisperKit.recommendedModels().supported.contains(spec.directoryName)
    }
}

public struct WhisperModelSpec: Equatable, Sendable {
    public static let defaultRepository = "argmaxinc/whisperkit-coreml"

    public let model: WhisperModel
    public let variant: String
    public let directoryName: String
    public let repository: String

    public init(
        model: WhisperModel,
        variant: String,
        directoryName: String,
        repository: String = Self.defaultRepository
    ) {
        self.model = model
        self.variant = variant
        self.directoryName = directoryName
        self.repository = repository
    }
}

public enum WhisperDecodingTask: String, Codable, Sendable {
    case transcribe
    case translate
}

public struct WhisperDecodingOptions: Equatable, Sendable {
    public let language: String?
    public let task: WhisperDecodingTask

    public init(
        language: String? = nil,
        task: WhisperDecodingTask = .transcribe
    ) {
        let normalizedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.language = normalizedLanguage?.isEmpty == false
            ? normalizedLanguage
            : nil
        self.task = task
    }
}

public struct WhisperTranscript: Equatable, Sendable {
    public let text: String
    public let model: WhisperModel
    public let language: String?
    public let audioSeconds: Double
    public let transcriptionSeconds: Double
    public let timesFasterThanRealtime: Double
    public let segments: [TranscriptSegment]

    public init(
        text: String,
        model: WhisperModel,
        language: String?,
        audioSeconds: Double,
        transcriptionSeconds: Double,
        timesFasterThanRealtime: Double,
        segments: [TranscriptSegment] = []
    ) {
        self.text = text
        self.model = model
        self.language = language
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.timesFasterThanRealtime = timesFasterThanRealtime
        self.segments = segments
    }
}

public enum CoreMLWhisperError: LocalizedError {
    case modelNotInstalled(URL)
    case modelNotLoaded
    case downloadIncomplete(URL)
    case installDestinationExists(URL)
    case downloadCleanupFailed(String)
    case modelStorageInUse
    case emptyTranscription
    case unsafeModelDirectory(URL)
    case unsafeDownloadLocation(URL)
    case activityInProgress(CoreMLModelActivity)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let directory):
            "The Whisper model is not installed at \(directory.path)."
        case .modelNotLoaded:
            "Load the Whisper model before transcribing."
        case .downloadIncomplete:
            "The Whisper model download did not finish."
        case .installDestinationExists(let directory):
            "A model folder already exists at \(directory.path)."
        case .downloadCleanupFailed(let reason):
            "The incomplete model could not be removed: \(reason)"
        case .modelStorageInUse:
            "Another Tiro process is currently using the model library."
        case .emptyTranscription:
            "WhisperKit returned no transcription result."
        case .unsafeModelDirectory(let directory):
            "Refusing to delete a model outside its configured root: \(directory.path)."
        case .unsafeDownloadLocation(let directory):
            "WhisperKit returned a download outside its temporary cache: \(directory.path)."
        case .activityInProgress(let activity):
            "The Whisper model is currently \(activity.rawValue)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .downloadIncomplete:
            "Check your internet connection and try the download again."
        default:
            nil
        }
    }
}

struct WhisperRuntimeTranscript: Sendable {
    let text: String
    let language: String?
    let audioSeconds: Double
    let transcriptionSeconds: Double
    let timesFasterThanRealtime: Double
    let segments: [TranscriptSegment]

    init(
        text: String,
        language: String?,
        audioSeconds: Double,
        transcriptionSeconds: Double,
        timesFasterThanRealtime: Double,
        segments: [TranscriptSegment] = []
    ) {
        self.text = text
        self.language = language
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.timesFasterThanRealtime = timesFasterThanRealtime
        self.segments = segments
    }
}

protocol WhisperCoreMLSession: Sendable {
    func transcribe(
        _ audioURL: URL,
        options: WhisperDecodingOptions
    ) async throws -> WhisperRuntimeTranscript

    func unload() async
}

protocol WhisperCoreMLRuntime: Sendable {
    func isInstalled(model: WhisperModelSpec, at directory: URL) async -> Bool

    func download(
        model: WhisperModelSpec,
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    func makeSession(
        model: WhisperModelSpec,
        from directory: URL
    ) async throws -> any WhisperCoreMLSession
}

struct WhisperKitRuntime: WhisperCoreMLRuntime {
    func isInstalled(model: WhisperModelSpec, at directory: URL) async -> Bool {
        Self.hasRequiredModelBundles(in: directory)
    }

    func download(
        model: WhisperModelSpec,
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let root = directory.deletingLastPathComponent()
        let identifier = UUID().uuidString
        let stagingRoot = root
            .appendingPathComponent(
                ".whisperkit-download-\(model.directoryName)-\(identifier)",
                isDirectory: true
            )
        let candidate = root
            .appendingPathComponent(".\(model.directoryName)-installing-\(identifier)", isDirectory: true)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            try? fileManager.removeItem(at: candidate)
        }

        let downloaded = try await WhisperKit.download(
            variant: model.variant,
            downloadBase: stagingRoot,
            from: model.repository
        ) { update in
            progress(update.fractionCompleted)
        }
        try Task.checkCancellation()

        guard Self.isDescendant(downloaded, of: stagingRoot) else {
            throw CoreMLWhisperError.unsafeDownloadLocation(downloaded)
        }
        guard Self.hasRequiredModelBundles(in: downloaded) else {
            throw CoreMLWhisperError.downloadIncomplete(downloaded)
        }

        try fileManager.moveItem(at: downloaded, to: candidate)
        try Task.checkCancellation()
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw CoreMLWhisperError.installDestinationExists(directory)
        }
        try fileManager.moveItem(at: candidate, to: directory)
    }

    func makeSession(
        model: WhisperModelSpec,
        from directory: URL
    ) async throws -> any WhisperCoreMLSession {
        guard Self.hasRequiredModelBundles(in: directory) else {
            throw CoreMLWhisperError.modelNotInstalled(directory)
        }

        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        let configuration = WhisperKitConfig(
            modelFolder: directory.path,
            tokenizerFolder: directory,
            computeOptions: compute,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(configuration)
        return WhisperKitSession(whisperKit: whisperKit)
    }

    private static func hasRequiredModelBundles(in directory: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
            .allSatisfy { name in
                FileManager.default.fileExists(
                    atPath: ModelUtilities.detectModelURL(
                        inFolder: directory,
                        named: name
                    ).path
                )
            }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let resolvedCandidate = candidate
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedRoot = root
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
    }
}

private actor WhisperKitSession: WhisperCoreMLSession {
    private var whisperKit: WhisperKit?

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    func transcribe(
        _ audioURL: URL,
        options: WhisperDecodingOptions
    ) async throws -> WhisperRuntimeTranscript {
        guard let whisperKit else {
            throw CoreMLWhisperError.modelNotLoaded
        }

        let decodeOptions = DecodingOptions(
            task: options.task == .translate ? .translate : .transcribe,
            language: options.language,
            usePrefillPrompt: true,
            detectLanguage: options.language == nil,
            withoutTimestamps: false,
            wordTimestamps: true
        )
        let start = Date()
        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: decodeOptions
        )
        let elapsed = Date().timeIntervalSince(start)
        guard !results.isEmpty else {
            throw CoreMLWhisperError.emptyTranscription
        }

        let text = results
            .map { WhisperTextSanitizer.clean($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let audioSeconds = results.reduce(0) {
            $0 + $1.timings.inputAudioSeconds
        }
        let language = results.lazy
            .map(\.language)
            .first(where: { !$0.isEmpty })
        let segments: [TranscriptSegment] = results.flatMap(\.segments).compactMap { segment in
            let text = WhisperTextSanitizer.clean(segment.text)
            let words: [TranscriptWord] = (segment.words ?? []).compactMap {
                let text = WhisperTextSanitizer.clean($0.word)
                guard !text.isEmpty else { return nil }
                return TranscriptWord(
                    text: text,
                    startSeconds: Double($0.start),
                    endSeconds: Double($0.end)
                )
            }
            guard !text.isEmpty || !words.isEmpty else { return nil }
            return TranscriptSegment(
                text: text,
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end),
                words: words
            )
        }

        return WhisperRuntimeTranscript(
            text: text,
            language: language,
            audioSeconds: audioSeconds,
            transcriptionSeconds: elapsed,
            timesFasterThanRealtime: elapsed > 0 ? audioSeconds / elapsed : 0,
            segments: segments
        )
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }
}

enum WhisperTextSanitizer {
    private static let controlToken = try! NSRegularExpression(
        pattern: #"<\|[^|]*\|>"#
    )

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = controlToken.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: " "
        )
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public actor CoreMLWhisperEngine: RecognitionEngine {
    public nonisolated let model: WhisperModel
    public nonisolated let spec: WhisperModelSpec
    public nonisolated let modelsRootDirectory: URL
    public nonisolated let modelDirectory: URL

    private let runtime: any WhisperCoreMLRuntime
    private let progressState = WhisperDownloadProgressState()
    private var session: (any WhisperCoreMLSession)?
    private var loadTask: (
        id: UUID,
        task: Task<any WhisperCoreMLSession, Error>
    )?
    private var activity = CoreMLModelActivity.idle
    private var lastError: String?
    private var cachedSizeBytes: Int64?

    public init(
        model: WhisperModel,
        modelsRootDirectory: URL
    ) {
        self.init(
            model: model,
            modelsRootDirectory: modelsRootDirectory,
            runtime: WhisperKitRuntime()
        )
    }

    init(
        model: WhisperModel,
        modelsRootDirectory: URL,
        runtime: any WhisperCoreMLRuntime
    ) {
        let root = modelsRootDirectory.standardizedFileURL
        self.model = model
        spec = model.spec
        self.modelsRootDirectory = root
        modelDirectory = root
            .appendingPathComponent(model.spec.directoryName, isDirectory: true)
            .standardizedFileURL
        self.runtime = runtime
    }

    public func status() async -> CoreMLModelStatus {
        let installed = await runtime.isInstalled(
            model: spec,
            at: modelDirectory
        )
        if installed, cachedSizeBytes == nil {
            cachedSizeBytes = Self.directorySize(at: modelDirectory)
        } else if !installed {
            cachedSizeBytes = nil
        }
        return CoreMLModelStatus(
            directory: modelDirectory,
            installed: installed,
            loaded: session != nil,
            sizeBytes: installed ? cachedSizeBytes ?? 0 : 0,
            activity: activity,
            downloadProgress: activity == .downloading ? progressState.value : nil,
            lastError: lastError
        )
    }

    public func download(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try begin(.downloading)
        defer {
            activity = .idle
            progressState.value = nil
        }
        guard isConfiguredModelDirectorySafe else {
            throw CoreMLWhisperError.unsafeModelDirectory(modelDirectory)
        }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw CoreMLWhisperError.modelStorageInUse
        }
        defer { lease.release() }

        if await runtime.isInstalled(model: spec, at: modelDirectory) {
            progress(1)
            return
        }

        lastError = nil
        progressState.value = 0
        do {
            try await removeIncompleteModelDirectory()
            try cleanupDownloadArtifacts()
            try await runtime.download(
                model: spec,
                to: modelDirectory
            ) { [progressState] fraction in
                let bounded = min(1, max(0, fraction))
                progressState.value = bounded
                progress(bounded)
            }
            guard await runtime.isInstalled(model: spec, at: modelDirectory) else {
                throw CoreMLWhisperError.downloadIncomplete(modelDirectory)
            }
            progressState.value = 1
            cachedSizeBytes = Self.directorySize(at: modelDirectory)
            progress(1)
        } catch is CancellationError {
            lastError = nil
            do {
                try await cleanupFailedDownload()
            } catch {
                lastError = error.localizedDescription
                throw error
            }
            throw CancellationError()
        } catch {
            let originalError = error
            do {
                try await cleanupFailedDownload()
            } catch {
                let cleanupError = error
                lastError = cleanupError.localizedDescription
                throw cleanupError
            }
            lastError = originalError.localizedDescription
            throw originalError
        }
    }

    public func cleanupAbandonedDownload() async throws {
        try begin(.cleaning)
        defer { activity = .idle }
        guard isConfiguredModelDirectorySafe else {
            throw CoreMLWhisperError.unsafeModelDirectory(modelDirectory)
        }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw CoreMLWhisperError.modelStorageInUse
        }
        defer { lease.release() }
        try await removeIncompleteModelDirectory()
        try cleanupDownloadArtifacts()
    }

    public func load() async throws {
        if session != nil { return }
        if let pending = loadTask {
            let loadedSession = try await pending.task.value
            if loadTask?.id == pending.id {
                session = loadedSession
                loadTask = nil
                activity = .idle
            }
            return
        }

        try begin(.loading)
        lastError = nil
        let id = UUID()
        let runtime = runtime
        let spec = spec
        let directory = modelDirectory
        let task = Task<any WhisperCoreMLSession, Error> {
            guard await runtime.isInstalled(model: spec, at: directory) else {
                throw CoreMLWhisperError.modelNotInstalled(directory)
            }
            return try await runtime.makeSession(model: spec, from: directory)
        }
        loadTask = (id, task)

        do {
            let loadedSession = try await task.value
            guard loadTask?.id == id else {
                await loadedSession.unload()
                return
            }
            session = loadedSession
            loadTask = nil
            activity = .idle
        } catch {
            if loadTask?.id == id {
                lastError = error.localizedDescription
                loadTask = nil
                activity = .idle
            }
            throw error
        }
    }

    public func preload() async throws {
        try await load()
    }

    public func unload() async throws {
        if let pending = loadTask {
            let loadedSession = try await pending.task.value
            if loadTask?.id == pending.id {
                session = loadedSession
                loadTask = nil
                activity = .idle
            }
        }

        try begin(.loading)
        let loadedSession = session
        session = nil
        await loadedSession?.unload()
        activity = .idle
    }

    public func delete() async throws {
        guard isConfiguredModelDirectorySafe else {
            throw CoreMLWhisperError.unsafeModelDirectory(modelDirectory)
        }

        try begin(.deleting)
        defer { activity = .idle }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw CoreMLWhisperError.modelStorageInUse
        }
        defer { lease.release() }
        lastError = nil
        let loadedSession = session
        session = nil
        cachedSizeBytes = nil
        await loadedSession?.unload()

        do {
            if FileManager.default.fileExists(atPath: modelDirectory.path) {
                try FileManager.default.removeItem(at: modelDirectory)
            }
            try cleanupDownloadArtifacts()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func transcribe(
        _ audioURL: URL,
        options: WhisperDecodingOptions
    ) async throws -> WhisperTranscript {
        guard let session else {
            throw CoreMLWhisperError.modelNotLoaded
        }

        try begin(.transcribing)
        defer { activity = .idle }
        lastError = nil
        do {
            let result = try await session.transcribe(
                audioURL,
                options: options
            )
            return WhisperTranscript(
                text: result.text,
                model: model,
                language: result.language,
                audioSeconds: result.audioSeconds,
                transcriptionSeconds: result.transcriptionSeconds,
                timesFasterThanRealtime: result.timesFasterThanRealtime,
                segments: result.segments
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func transcribe(_ audioURL: URL) async throws -> RawTranscript {
        let transcript = try await transcribe(
            audioURL,
            options: WhisperDecodingOptions()
        )
        return RawTranscript(
            text: transcript.text,
            model: model.recognitionModel,
            audioSeconds: transcript.audioSeconds,
            transcriptionSeconds: transcript.transcriptionSeconds,
            timesFasterThanRealtime: transcript.timesFasterThanRealtime,
            segments: transcript.segments
        )
    }

    private func begin(_ nextActivity: CoreMLModelActivity) throws {
        guard activity == .idle else {
            throw CoreMLWhisperError.activityInProgress(activity)
        }
        activity = nextActivity
    }

    private var isConfiguredModelDirectorySafe: Bool {
        modelDirectory.lastPathComponent == spec.directoryName
            && modelDirectory.deletingLastPathComponent().standardizedFileURL
                == modelsRootDirectory
            && modelDirectoryRootIsSafe(modelsRootDirectory)
    }

    private func cleanupFailedDownload() async throws {
        do {
            try await removeIncompleteModelDirectory()
            try cleanupDownloadArtifacts()
        } catch {
            throw CoreMLWhisperError.downloadCleanupFailed(
                error.localizedDescription
            )
        }
    }

    private func removeIncompleteModelDirectory() async throws {
        guard isConfiguredModelDirectorySafe,
              FileManager.default.fileExists(atPath: modelDirectory.path) else { return }
        guard !(await runtime.isInstalled(model: spec, at: modelDirectory)) else { return }
        try FileManager.default.removeItem(at: modelDirectory)
        cachedSizeBytes = nil
    }

    private func cleanupDownloadArtifacts() throws {
        guard isConfiguredModelDirectorySafe else {
            throw CoreMLWhisperError.unsafeModelDirectory(modelDirectory)
        }
        let fileManager = FileManager.default
        let downloadPrefix = ".whisperkit-download-\(spec.directoryName)-"
        let installingPrefix = ".\(spec.directoryName)-installing-"
        guard fileManager.fileExists(atPath: modelsRootDirectory.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: modelsRootDirectory,
            includingPropertiesForKeys: nil
        )
        for child in children where
            child.lastPathComponent.hasPrefix(downloadPrefix)
                || child.lastPathComponent.hasPrefix(installingPrefix) {
            try fileManager.removeItem(at: child)
        }
    }

    private nonisolated static func directorySize(at directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return files.reduce(into: 0) { total, item in
            guard
                let url = item as? URL,
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else {
                return
            }
            total += Int64(values.fileSize ?? 0)
        }
    }
}

private final class WhisperDownloadProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Double?

    var value: Double? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
