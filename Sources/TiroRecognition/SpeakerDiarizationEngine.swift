import Foundation
import FluidAudio

public struct SpeakerInterval: Codable, Equatable, Sendable {
    public let speakerID: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(
        speakerID: String,
        startSeconds: Double,
        endSeconds: Double
    ) {
        self.speakerID = speakerID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct SpeakerDiarizationResult: Codable, Equatable, Sendable {
    public let intervals: [SpeakerInterval]

    public init(intervals: [SpeakerInterval]) {
        self.intervals = intervals
    }
}

public protocol SpeakerDiarizationRuntime: Sendable {
    func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult
}

public protocol ManagedSpeakerDiarizationRuntime: SpeakerDiarizationRuntime {
    func status() async -> CoreMLModelStatus
    func download(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func cleanupAbandonedDownload() async throws
    func unload() async throws
    func delete() async throws
}

public enum SpeakerDiarizationError: LocalizedError, Equatable {
    case modelNotInstalled(URL)
    case downloadIncomplete(URL)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case modelStorageInUse
    case unsafeModelDirectory(URL)
    case activityInProgress(CoreMLModelActivity)
    case lifecycleUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let directory):
            "The speaker diarisation model is not installed at \(directory.path)."
        case .downloadIncomplete:
            "The speaker diarisation model download did not finish."
        case .insufficientDiskSpace(let required, let available):
            "Speaker diarisation needs \(required) bytes of free space, but only \(available) bytes are available."
        case .modelStorageInUse:
            "Another Tiro process is currently using the model library."
        case .unsafeModelDirectory(let directory):
            "Refusing to modify a model outside its configured root: \(directory.path)."
        case .activityInProgress(let activity):
            "The speaker diarisation model is currently \(activity.rawValue)."
        case .lifecycleUnavailable:
            "This speaker diarisation runtime does not manage downloadable models."
        }
    }
}

public struct SpeakerDiarizationEngine: Sendable {
    private let runtime: any SpeakerDiarizationRuntime

    public init(runtime: any SpeakerDiarizationRuntime) {
        self.runtime = runtime
    }

    public func diarize(
        _ audioURL: URL,
        transcriptSegments: [TranscriptSegment]
    ) async throws -> [TranscriptSegment] {
        let result = try await runtime.diarize(audioURL)
        return Self.align(transcriptSegments, with: result)
    }

    public func status() async throws -> CoreMLModelStatus {
        guard let runtime = runtime as? any ManagedSpeakerDiarizationRuntime else {
            throw SpeakerDiarizationError.lifecycleUnavailable
        }
        return await runtime.status()
    }

    public func download(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let runtime = runtime as? any ManagedSpeakerDiarizationRuntime else {
            throw SpeakerDiarizationError.lifecycleUnavailable
        }
        try await runtime.download(progress: progress)
    }

    public func unload() async throws {
        guard let runtime = runtime as? any ManagedSpeakerDiarizationRuntime else {
            throw SpeakerDiarizationError.lifecycleUnavailable
        }
        try await runtime.unload()
    }

    public func cleanupAbandonedDownload() async throws {
        guard let runtime = runtime as? any ManagedSpeakerDiarizationRuntime else {
            throw SpeakerDiarizationError.lifecycleUnavailable
        }
        try await runtime.cleanupAbandonedDownload()
    }

    public func delete() async throws {
        guard let runtime = runtime as? any ManagedSpeakerDiarizationRuntime else {
            throw SpeakerDiarizationError.lifecycleUnavailable
        }
        try await runtime.delete()
    }

    public static func align(
        _ transcriptSegments: [TranscriptSegment],
        with diarization: SpeakerDiarizationResult
    ) -> [TranscriptSegment] {
        transcriptSegments.flatMap { segment in
            guard !segment.words.isEmpty else {
                return [
                    TranscriptSegment(
                        text: segment.text,
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds,
                        speakerID: speakerID(
                            from: segment.startSeconds,
                            to: segment.endSeconds,
                            intervals: diarization.intervals
                        )
                    )
                ]
            }

            return alignWords(
                segment.words,
                intervals: diarization.intervals
            )
        }
    }

    private static func alignWords(
        _ words: [TranscriptWord],
        intervals: [SpeakerInterval]
    ) -> [TranscriptSegment] {
        var groups: [(speakerID: String?, words: [TranscriptWord])] = []

        for word in words {
            let assignedSpeaker = speakerID(
                from: word.startSeconds,
                to: word.endSeconds,
                intervals: intervals
            )
            if groups.last?.speakerID == assignedSpeaker {
                groups[groups.count - 1].words.append(word)
            } else {
                groups.append((assignedSpeaker, [word]))
            }
        }

        return groups.compactMap { group in
            guard let first = group.words.first, let last = group.words.last else {
                return nil
            }
            return TranscriptSegment(
                text: joinedText(group.words),
                startSeconds: first.startSeconds,
                endSeconds: last.endSeconds,
                speakerID: group.speakerID,
                words: group.words
            )
        }
    }

    private static func speakerID(
        from startSeconds: Double,
        to endSeconds: Double,
        intervals: [SpeakerInterval]
    ) -> String? {
        guard endSeconds > startSeconds else {
            return nil
        }

        let midpoint = (startSeconds + endSeconds) / 2
        let candidates = intervals.compactMap { interval -> Candidate? in
            let overlap = min(endSeconds, interval.endSeconds)
                - max(startSeconds, interval.startSeconds)
            guard overlap > 0 else {
                return nil
            }
            return Candidate(
                interval: interval,
                overlap: overlap,
                containsMidpoint: interval.startSeconds <= midpoint
                    && midpoint < interval.endSeconds
            )
        }

        return candidates.sorted(by: Candidate.precedes).first?.interval.speakerID
    }

    private static func joinedText(_ words: [TranscriptWord]) -> String {
        words.map(\.text).reduce(into: "") { text, word in
            guard !text.isEmpty else {
                text = word
                return
            }
            if word.first?.isWhitespace == true
                || word.first.map(Self.attachesToPreviousWord) == true
            {
                text += word
            } else {
                text += " " + word
            }
        }
    }

    private static func attachesToPreviousWord(_ character: Character) -> Bool {
        character.isPunctuation && !"([{".contains(character)
    }

    private struct Candidate {
        let interval: SpeakerInterval
        let overlap: Double
        let containsMidpoint: Bool

        static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.overlap != rhs.overlap {
                return lhs.overlap > rhs.overlap
            }
            if lhs.containsMidpoint != rhs.containsMidpoint {
                return lhs.containsMidpoint
            }
            if lhs.interval.speakerID != rhs.interval.speakerID {
                return lhs.interval.speakerID < rhs.interval.speakerID
            }
            if lhs.interval.startSeconds != rhs.interval.startSeconds {
                return lhs.interval.startSeconds < rhs.interval.startSeconds
            }
            return lhs.interval.endSeconds < rhs.interval.endSeconds
        }
    }
}

@available(macOS 14.0, *)
public actor FluidAudioOfflineDiarizationRuntime: SpeakerDiarizationRuntime {
    private let manager: OfflineDiarizerManager

    public init(
        models: OfflineDiarizerModels,
        config: OfflineDiarizerConfig = .default
    ) {
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        self.manager = manager
    }

    public func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult {
        let result = try await manager.process(audioURL)
        return SpeakerDiarizationResult(
            intervals: result.segments.map {
                SpeakerInterval(
                    speakerID: $0.speakerId,
                    startSeconds: Double($0.startTimeSeconds),
                    endSeconds: Double($0.endTimeSeconds)
                )
            }
        )
    }
}

@available(macOS 14.0, *)
public actor FluidAudioOnDemandDiarizationRuntime: SpeakerDiarizationRuntime {
    public static let expectedDownloadBytes: Int64 = 1_000_000_000
    public static let minimumRemainingBytes: Int64 = 512_000_000

    private static let modelDirectoryName = "speaker-diarization-coreml"
    private static let stagingPrefix = ".diarization-download-"
    private static let installingPrefix = ".diarization-installing-"
    private static let requiredModelFiles = [
        "Segmentation.mlmodelc",
        "FBank.mlmodelc",
        "Embedding.mlmodelc",
        "PldaRho.mlmodelc",
        "plda-parameters.json",
    ]

    public nonisolated let modelsRootDirectory: URL
    public nonisolated let modelDirectory: URL
    private let runtime: any OfflineDiarizationModelRuntime
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let progressState = DiarizationProgressState()
    private var session: (any OfflineDiarizationSession)?
    private var activity = CoreMLModelActivity.idle
    private var lastError: String?
    private var cachedSizeBytes: Int64?

    public init(
        modelsRootDirectory: URL,
        config: OfflineDiarizerConfig = .default
    ) {
        self.init(
            modelsRootDirectory: modelsRootDirectory,
            runtime: FluidAudioOfflineDiarizationModelRuntime(config: config),
            availableCapacity: { Self.volumeAvailableCapacity(at: $0) }
        )
    }

    init(
        modelsRootDirectory: URL,
        runtime: any OfflineDiarizationModelRuntime,
        availableCapacity: @escaping @Sendable (URL) -> Int64?
    ) {
        let root = modelsRootDirectory.standardizedFileURL
        self.modelsRootDirectory = root
        modelDirectory = root.appendingPathComponent(
            Self.modelDirectoryName,
            isDirectory: true
        )
        self.runtime = runtime
        self.availableCapacity = availableCapacity
    }

    public func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult {
        if !(await runtime.isInstalled(at: modelDirectory)) {
            try await download()
        }
        try await load()
        guard let session else {
            throw SpeakerDiarizationError.modelNotInstalled(modelDirectory)
        }
        try begin(.transcribing)
        defer { activity = .idle }
        do {
            return try await session.diarize(audioURL)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func status() async -> CoreMLModelStatus {
        let installed = await runtime.isInstalled(at: modelDirectory)
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
            throw SpeakerDiarizationError.unsafeModelDirectory(modelDirectory)
        }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw SpeakerDiarizationError.modelStorageInUse
        }
        defer { lease.release() }

        if await runtime.isInstalled(at: modelDirectory) {
            progress(1)
            return
        }

        let requiredBytes = Self.expectedDownloadBytes + Self.minimumRemainingBytes
        if let available = availableCapacity(modelsRootDirectory), available < requiredBytes {
            throw SpeakerDiarizationError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: available
            )
        }

        lastError = nil
        progressState.value = 0
        let stagingRoot = modelsRootDirectory.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        let candidate = modelsRootDirectory.appendingPathComponent(
            Self.installingPrefix + UUID().uuidString,
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: candidate)
        }

        do {
            try removeIncompleteModel()
            try cleanupDownloadArtifacts(excluding: [stagingRoot, candidate])
            try FileManager.default.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true
            )
            try await runtime.download(to: stagingRoot) { [progressState] update in
                let reported = progressState.advance(
                    to: min(0.95, max(0, update))
                )
                progress(reported)
            }
            try Task.checkCancellation()

            let stagedModel = stagingRoot.appendingPathComponent(
                modelDirectory.lastPathComponent,
                isDirectory: true
            )
            guard Self.hasRequiredModelFiles(at: stagedModel) else {
                throw SpeakerDiarizationError.downloadIncomplete(stagedModel)
            }
            try FileManager.default.moveItem(at: stagedModel, to: candidate)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: candidate, to: modelDirectory)
            cachedSizeBytes = Self.directorySize(at: modelDirectory)
            progressState.value = 1
            progress(1)
        } catch is CancellationError {
            lastError = nil
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func load() async throws {
        if session != nil { return }
        try begin(.loading)
        defer { activity = .idle }
        lastError = nil
        guard await runtime.isInstalled(at: modelDirectory) else {
            throw SpeakerDiarizationError.modelNotInstalled(modelDirectory)
        }
        do {
            session = try await runtime.makeSession(from: modelsRootDirectory)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func unload() async throws {
        try begin(.loading)
        session = nil
        activity = .idle
    }

    public func delete() async throws {
        guard isConfiguredModelDirectorySafe else {
            throw SpeakerDiarizationError.unsafeModelDirectory(modelDirectory)
        }
        try begin(.deleting)
        defer { activity = .idle }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw SpeakerDiarizationError.modelStorageInUse
        }
        defer { lease.release() }
        lastError = nil
        session = nil
        cachedSizeBytes = nil
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

    public func cleanupAbandonedDownload() async throws {
        try begin(.cleaning)
        defer { activity = .idle }
        guard isConfiguredModelDirectorySafe else {
            throw SpeakerDiarizationError.unsafeModelDirectory(modelDirectory)
        }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw SpeakerDiarizationError.modelStorageInUse
        }
        defer { lease.release() }
        try cleanupDownloadArtifacts()
    }

    private func begin(_ nextActivity: CoreMLModelActivity) throws {
        guard activity == .idle else {
            throw SpeakerDiarizationError.activityInProgress(activity)
        }
        activity = nextActivity
    }

    private var isConfiguredModelDirectorySafe: Bool {
        modelDirectory.lastPathComponent == Self.modelDirectoryName
            && modelDirectory.deletingLastPathComponent().standardizedFileURL
                == modelsRootDirectory
            && modelDirectoryRootIsSafe(modelsRootDirectory)
    }

    private func removeIncompleteModel() throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path),
              !Self.hasRequiredModelFiles(at: modelDirectory) else {
            return
        }
        try FileManager.default.removeItem(at: modelDirectory)
        cachedSizeBytes = nil
    }

    private func cleanupDownloadArtifacts(excluding retained: [URL] = []) throws {
        guard isConfiguredModelDirectorySafe else {
            throw SpeakerDiarizationError.unsafeModelDirectory(modelDirectory)
        }
        guard FileManager.default.fileExists(atPath: modelsRootDirectory.path) else {
            return
        }
        let retained = Set(retained.map(\.standardizedFileURL))
        let children = try FileManager.default.contentsOfDirectory(
            at: modelsRootDirectory,
            includingPropertiesForKeys: nil
        )
        for child in children where
            (child.lastPathComponent.hasPrefix(Self.stagingPrefix)
                || child.lastPathComponent.hasPrefix(Self.installingPrefix))
                && !retained.contains(child.standardizedFileURL) {
            try FileManager.default.removeItem(at: child)
        }
    }

    static func hasRequiredModelFiles(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        return requiredModelFiles.allSatisfy { name in
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) else {
                return false
            }
            if name.hasSuffix(".mlmodelc") {
                return isDirectory.boolValue
                    && ((try? fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil
                    ).isEmpty) == false)
            }
            return !isDirectory.boolValue
                && ((try? url.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize) ?? 0) > 0
        }
    }

    private nonisolated static func volumeAvailableCapacity(at directory: URL) -> Int64? {
        var candidate = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return try? candidate.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ]).volumeAvailableCapacityForImportantUsage
    }

    private nonisolated static func directorySize(at directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(into: 0) { total, item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }
}

@available(macOS 14.0, *)
extension FluidAudioOnDemandDiarizationRuntime: ManagedSpeakerDiarizationRuntime {}

@available(macOS 14.0, *)
protocol OfflineDiarizationSession: Sendable {
    func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult
}

@available(macOS 14.0, *)
protocol OfflineDiarizationModelRuntime: Sendable {
    func isInstalled(at modelDirectory: URL) async -> Bool
    func download(
        to modelsRootDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func makeSession(
        from modelsRootDirectory: URL
    ) async throws -> any OfflineDiarizationSession
}

@available(macOS 14.0, *)
private struct FluidAudioOfflineDiarizationModelRuntime: OfflineDiarizationModelRuntime {
    let config: OfflineDiarizerConfig

    func isInstalled(at modelDirectory: URL) async -> Bool {
        FluidAudioOnDemandDiarizationRuntime.hasRequiredModelFiles(at: modelDirectory)
    }

    func download(
        to modelsRootDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await FluidAudioBackendAccess.run(offline: false) {
            try await OfflineDiarizerModels.load(
                from: modelsRootDirectory,
                progressHandler: { progress($0.fractionCompleted) }
            )
        }
    }

    func makeSession(
        from modelsRootDirectory: URL
    ) async throws -> any OfflineDiarizationSession {
        let models = try await FluidAudioBackendAccess.run(offline: true) {
            try await OfflineDiarizerModels.load(from: modelsRootDirectory)
        }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        return FluidAudioDiarizationSession(manager: manager)
    }
}

@available(macOS 14.0, *)
private actor FluidAudioDiarizationSession: OfflineDiarizationSession {
    let manager: OfflineDiarizerManager

    init(manager: OfflineDiarizerManager) {
        self.manager = manager
    }

    func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult {
        let result = try await manager.process(audioURL)
        return SpeakerDiarizationResult(
            intervals: result.segments.map {
                SpeakerInterval(
                    speakerID: $0.speakerId,
                    startSeconds: Double($0.startTimeSeconds),
                    endSeconds: Double($0.endTimeSeconds)
                )
            }
        )
    }
}

private final class DiarizationProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Double?

    var value: Double? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }

    func advance(to value: Double) -> Double {
        lock.withLock {
            let next = max(storedValue ?? 0, value)
            storedValue = next
            return next
        }
    }
}
