import CoreML
import FluidAudio
import Foundation

public enum CoreMLParakeetError: LocalizedError {
    case modelNotInstalled(URL)
    case modelNotLoaded
    case downloadIncomplete(URL)
    case installDestinationExists(URL)
    case downloadCleanupFailed(String)
    case modelStorageInUse
    case unsafeModelDirectory(URL)
    case activityInProgress(CoreMLModelActivity)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let directory):
            return "The Core ML Parakeet model is not installed at \(directory.path)."
        case .modelNotLoaded:
            return "Load the Core ML Parakeet model before transcribing."
        case .downloadIncomplete:
            return "The Core ML Parakeet model download did not finish."
        case .installDestinationExists(let directory):
            return "A model folder already exists at \(directory.path)."
        case .downloadCleanupFailed(let reason):
            return "The incomplete model could not be removed: \(reason)"
        case .modelStorageInUse:
            return "Another Tiro process is currently using the model library."
        case .unsafeModelDirectory(let directory):
            return "Refusing to delete a model outside its configured root: \(directory.path)."
        case .activityInProgress(let activity):
            return "The Core ML Parakeet model is currently \(activity.rawValue)."
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

struct RuntimeTranscript: Sendable {
    let text: String
    let audioSeconds: Double
    let transcriptionSeconds: Double
    let timesFasterThanRealtime: Double
}

protocol CompactCoreMLSession: Sendable {
    func transcribe(_ audioURL: URL) async throws -> RuntimeTranscript
}

protocol CompactCoreMLRuntime: Sendable {
    func isInstalled(at directory: URL) async -> Bool
    func download(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func makeSession(from directory: URL) async throws -> any CompactCoreMLSession
}

struct FluidAudioRuntime: CompactCoreMLRuntime {
    let model: ParakeetModel

    init(model: ParakeetModel = .compact) {
        self.model = model
    }

    func isInstalled(at directory: URL) async -> Bool {
        AsrModels.modelsExist(at: directory, version: model.fluidAudioVersion)
    }

    func download(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let root = directory.deletingLastPathComponent()
        let identifier = UUID().uuidString
        let staging = root.appendingPathComponent(
            "\(model.downloadStagingPrefix)\(identifier)",
            isDirectory: true
        )
        let candidate = root.appendingPathComponent(
            "\(model.installingPrefix)\(identifier)",
            isDirectory: true
        )

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: candidate)
        }

        try await Self.withNetworkAccess {
            try Task.checkCancellation()
            _ = try await AsrModels.download(
                to: staging,
                version: model.fluidAudioVersion,
                progressHandler: { update in
                    progress(update.fractionCompleted)
                }
            )
            try Task.checkCancellation()
        }

        guard AsrModels.modelsExist(at: staging, version: model.fluidAudioVersion) else {
            throw CoreMLParakeetError.downloadIncomplete(staging)
        }
        try fileManager.moveItem(at: staging, to: candidate)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: directory.path) {
            guard AsrModels.modelsExist(
                at: directory,
                version: model.fluidAudioVersion
            ) else {
                throw CoreMLParakeetError.installDestinationExists(directory)
            }
            return
        }
        try fileManager.moveItem(at: candidate, to: directory)
    }

    func makeSession(from directory: URL) async throws -> any CompactCoreMLSession {
        try await Self.withOfflineAccess {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await AsrModels.load(
                from: directory,
                configuration: configuration,
                version: model.fluidAudioVersion
            )
            let manager = AsrManager()
            try await manager.loadModels(models)
            return FluidAudioSession(manager: manager)
        }
    }

    static func withNetworkAccess<T>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await FluidAudioBackendAccess.run(offline: false, operation)
    }

    static func withOfflineAccess<T>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await FluidAudioBackendAccess.run(offline: true, operation)
    }

    static func backendOfflineMode() async -> Bool {
        await FluidAudioBackendAccess.currentMode()
    }
}

private extension ParakeetModel {
    var downloadStagingPrefix: String { ".\(directoryName)-download-" }
    var installingPrefix: String { ".\(directoryName)-installing-" }

    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .compact: .tdtCtc110m
        case .v2: .v2
        case .v3: .v3
        }
    }
}

private enum FluidAudioBackendAccess {
    private static let lock = AsyncLock()

    static func currentMode() async -> Bool {
        await lock.acquire()
        let mode = ModelHub.offlineMode
        await lock.release()
        return mode
    }

    static func run<T>(
        offline: Bool,
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await lock.acquire()
        let previous = ModelHub.offlineMode
        ModelHub.offlineMode = offline
        do {
            let result = try await operation()
            ModelHub.offlineMode = previous
            await lock.release()
            return result
        } catch {
            ModelHub.offlineMode = previous
            await lock.release()
            throw error
        }
    }
}

private actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private actor FluidAudioSession: CompactCoreMLSession {
    private let manager: AsrManager

    init(manager: AsrManager) {
        self.manager = manager
    }

    func transcribe(_ audioURL: URL) async throws -> RuntimeTranscript {
        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState
        )
        return RuntimeTranscript(
            text: result.text,
            audioSeconds: result.duration,
            transcriptionSeconds: result.processingTime,
            timesFasterThanRealtime: Double(result.rtfx)
        )
    }
}

public actor CoreMLParakeetEngine: RecognitionEngine {
    public static let canonicalDirectoryName = "parakeet-tdt-ctc-110m"

    public nonisolated let model: ParakeetModel
    public nonisolated let modelsRootDirectory: URL
    public nonisolated let modelDirectory: URL

    private let runtime: any CompactCoreMLRuntime
    private let progressState = DownloadProgressState()
    private var session: (any CompactCoreMLSession)?
    private var preloadTask: (
        id: UUID,
        task: Task<any CompactCoreMLSession, Error>
    )?
    private var activity = CoreMLModelActivity.idle
    private var lastError: String?
    private var cachedSizeBytes: Int64?

    public init(
        model: ParakeetModel = .compact,
        modelsRootDirectory: URL
    ) {
        self.init(
            model: model,
            modelsRootDirectory: modelsRootDirectory,
            runtime: FluidAudioRuntime(model: model)
        )
    }

    init(
        model: ParakeetModel = .compact,
        modelsRootDirectory: URL,
        runtime: any CompactCoreMLRuntime
    ) {
        let root = modelsRootDirectory.standardizedFileURL
        self.model = model
        self.modelsRootDirectory = root
        modelDirectory = root
            .appendingPathComponent(model.directoryName, isDirectory: true)
            .standardizedFileURL
        self.runtime = runtime
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
            throw CoreMLParakeetError.unsafeModelDirectory(modelDirectory)
        }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw CoreMLParakeetError.modelStorageInUse
        }
        defer { lease.release() }

        if await runtime.isInstalled(at: modelDirectory) {
            progress(1)
            return
        }

        lastError = nil
        progressState.value = 0

        do {
            try await removeIncompleteModelDirectory()
            try cleanupDownloadArtifacts()
            try await runtime.download(to: modelDirectory) { [progressState] fraction in
                let bounded = min(1, max(0, fraction))
                progressState.value = bounded
                progress(bounded)
            }
            guard await runtime.isInstalled(at: modelDirectory) else {
                throw CoreMLParakeetError.downloadIncomplete(modelDirectory)
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
            throw CoreMLParakeetError.unsafeModelDirectory(modelDirectory)
        }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw CoreMLParakeetError.modelStorageInUse
        }
        defer { lease.release() }
        try await removeIncompleteModelDirectory()
        try cleanupDownloadArtifacts()
    }

    public func preload() async throws {
        if session != nil { return }
        if let pending = preloadTask {
            let loadedSession = try await pending.task.value
            if preloadTask?.id == pending.id {
                session = loadedSession
                preloadTask = nil
                activity = .idle
            }
            return
        }
        try begin(.loading)
        lastError = nil
        let id = UUID()
        let runtime = runtime
        let directory = modelDirectory
        let task = Task<any CompactCoreMLSession, Error> {
            guard await runtime.isInstalled(at: directory) else {
                throw CoreMLParakeetError.modelNotInstalled(directory)
            }
            return try await runtime.makeSession(from: directory)
        }
        preloadTask = (id, task)
        do {
            let loadedSession = try await task.value
            guard preloadTask?.id == id else { return }
            session = loadedSession
            preloadTask = nil
            activity = .idle
        } catch {
            if preloadTask?.id == id {
                lastError = error.localizedDescription
                preloadTask = nil
                activity = .idle
            }
            throw error
        }
    }

    public func unload() async throws {
        if let pending = preloadTask {
            _ = try await pending.task.value
            if preloadTask?.id == pending.id {
                preloadTask = nil
                activity = .idle
            }
        }
        try begin(.loading)
        session = nil
        activity = .idle
    }

    public func delete() async throws {
        guard isConfiguredModelDirectorySafe else {
            throw CoreMLParakeetError.unsafeModelDirectory(modelDirectory)
        }

        try begin(.deleting)
        defer { activity = .idle }
        guard let lease = ModelDirectoryLease.acquire(at: modelsRootDirectory) else {
            throw CoreMLParakeetError.modelStorageInUse
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

    public func transcribe(_ audioURL: URL) async throws -> RawTranscript {
        guard let session else {
            throw CoreMLParakeetError.modelNotLoaded
        }

        try begin(.transcribing)
        defer { activity = .idle }
        lastError = nil
        do {
            let result = try await session.transcribe(audioURL)
            return RawTranscript(
                text: result.text,
                model: model.recognitionModel,
                audioSeconds: result.audioSeconds,
                transcriptionSeconds: result.transcriptionSeconds,
                timesFasterThanRealtime: result.timesFasterThanRealtime
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func begin(_ nextActivity: CoreMLModelActivity) throws {
        guard activity == .idle else {
            throw CoreMLParakeetError.activityInProgress(activity)
        }
        activity = nextActivity
    }

    private var isConfiguredModelDirectorySafe: Bool {
        modelDirectory.lastPathComponent == model.directoryName
            && modelDirectory.deletingLastPathComponent().standardizedFileURL
                == modelsRootDirectory
            && modelDirectoryRootIsSafe(modelsRootDirectory)
    }

    private func cleanupFailedDownload() async throws {
        do {
            try await removeIncompleteModelDirectory()
            try cleanupDownloadArtifacts()
        } catch {
            throw CoreMLParakeetError.downloadCleanupFailed(
                error.localizedDescription
            )
        }
    }

    private func removeIncompleteModelDirectory() async throws {
        guard isConfiguredModelDirectorySafe,
              FileManager.default.fileExists(atPath: modelDirectory.path) else { return }
        guard !(await runtime.isInstalled(at: modelDirectory)) else { return }
        try FileManager.default.removeItem(at: modelDirectory)
        cachedSizeBytes = nil
    }

    private func cleanupDownloadArtifacts() throws {
        guard isConfiguredModelDirectorySafe else {
            throw CoreMLParakeetError.unsafeModelDirectory(modelDirectory)
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelsRootDirectory.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: modelsRootDirectory,
            includingPropertiesForKeys: nil
        )
        for child in children where
            child.lastPathComponent.hasPrefix(model.downloadStagingPrefix)
                || child.lastPathComponent.hasPrefix(model.installingPrefix) {
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

private final class DownloadProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Double?

    var value: Double? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
