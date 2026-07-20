import Foundation
import Testing
@testable import TiroRecognition

@Suite(.serialized)
struct CoreMLParakeetEngineTests {
    @Test
    func testDerivesCanonicalDirectoryFromConfiguredRoot() {
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: URL(fileURLWithPath: "/tmp/tiro-coreml")
        )

        #expect(engine.modelsRootDirectory.path == "/tmp/tiro-coreml")
        #expect(
            engine.modelDirectory.path
                == "/tmp/tiro-coreml/parakeet-tdt-ctc-110m"
        )
    }

    @Test
    func testReportsMissingModelWithoutLoadingIt() async {
        let runtime = RuntimeStub()
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: URL(fileURLWithPath: "/tmp/tiro-coreml"),
            runtime: runtime
        )

        let status = await engine.status()
        let makeSessionCount = await runtime.makeSessionCount

        #expect(!status.installed)
        #expect(!status.loaded)
        #expect(status.sizeBytes == 0)
        #expect(status.activity == .idle)
        #expect(makeSessionCount == 0)
    }

    @Test
    func testDownloadPublishesProgressAndRequiresCompleteInstallation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeStub(downloadCreatesInstallation: true)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )
        let progress = ProgressRecorder()

        try await engine.download { progress.append($0) }
        let status = await engine.status()
        let downloadCount = await runtime.downloadCount

        #expect(downloadCount == 1)
        #expect(progress.values == [0.25, 0.75, 1])
        #expect(status.installed)
        #expect(status.sizeBytes == 12)
        #expect(status.activity == .idle)
        #expect(status.downloadProgress == nil)
    }

    @Test
    func testIncompleteDownloadIsRejectedAndRecorded() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeStub(downloadCreatesInstallation: false)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )

        do {
            try await engine.download()
            Issue.record("Expected an incomplete download error")
        } catch is CoreMLParakeetError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let status = await engine.status()
        #expect(!status.installed)
        #expect(status.activity == .idle)
        #expect(status.lastError != nil)
    }

    @Test
    func testCancellationRemovesPartialModelWithoutRecordingFailure() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeStub(downloadThrowsCancellation: true)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )

        do {
            try await engine.download()
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let status = await engine.status()
        #expect(!FileManager.default.fileExists(atPath: engine.modelDirectory.path))
        #expect(status.lastError == nil)
    }

    @Test
    func testCleanupRemovesInterruptedArtifactsAndKeepsSiblings() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CoreMLParakeetEngine(
            model: .compact,
            modelsRootDirectory: root,
            runtime: RuntimeStub()
        )
        let staging = root.appendingPathComponent(
            ".parakeet-tdt-ctc-110m-download-interrupted"
        )
        let sibling = root.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(
            at: engine.modelDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: sibling)

        try await engine.cleanupAbandonedDownload()

        #expect(!FileManager.default.fileExists(atPath: engine.modelDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test
    func testCleanupRejectsSymlinkedModelRoot() async throws {
        let container = temporaryDirectory()
        let realRoot = container.appendingPathComponent("real", isDirectory: true)
        let linkedRoot = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )
        let staging = realRoot.appendingPathComponent(
            ".parakeet-tdt-ctc-110m-download-keep"
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: linkedRoot,
            runtime: RuntimeStub()
        )

        do {
            try await engine.cleanupAbandonedDownload()
            Issue.record("Expected unsafe model directory error")
        } catch CoreMLParakeetError.unsafeModelDirectory {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test
    func testModelDirectoryLeaseExcludesAnotherLocalOwner() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try #require(ModelDirectoryLease.acquire(at: root))
        #expect(ModelDirectoryLease.acquire(at: root) == nil)
        first.release()

        let next = try #require(ModelDirectoryLease.acquire(at: root))
        next.release()
    }

    @Test
    func testPreloadAndTranscribeUseOwnedSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeStub(installed: true)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )

        try await engine.preload()
        let transcript = try await engine.transcribe(
            URL(fileURLWithPath: "/tmp/voice.wav")
        )
        let makeSessionCount = await runtime.makeSessionCount
        let status = await engine.status()

        #expect(makeSessionCount == 1)
        #expect(transcript.text == "Hello from Core ML.")
        #expect(transcript.model == .parakeetCompactCoreML)
        #expect(transcript.audioSeconds == 4)
        #expect(transcript.transcriptionSeconds == 0.05)
        #expect(transcript.timesFasterThanRealtime == 80)
        #expect(status.loaded)
    }

    @Test
    func testConcurrentPreloadsJoinOneModelLoad() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeStub(installed: true, sessionDelay: 0.05)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )

        async let first: Void = engine.preload()
        async let second: Void = engine.preload()
        _ = try await (first, second)

        #expect(await runtime.makeSessionCount == 1)
        #expect(await engine.status().loaded)
    }

    @Test
    func testUnloadReleasesTheLoadedSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: RuntimeStub(installed: true)
        )

        try await engine.preload()
        try await engine.unload()

        #expect(!(await engine.status()).loaded)
    }

    @Test
    func testTranscribeRequiresPreload() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeStub(installed: true)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )

        do {
            _ = try await engine.transcribe(URL(fileURLWithPath: "/tmp/voice.wav"))
            Issue.record("Expected a model-not-loaded error")
        } catch CoreMLParakeetError.modelNotLoaded {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testDeleteRemovesOnlyCanonicalModelDirectoryAndUnloadsSession() async throws {
        let root = temporaryDirectory()
        let model = root.appendingPathComponent(CoreMLParakeetEngine.canonicalDirectoryName)
        let sibling = root.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4).write(to: model.appendingPathComponent("model"))
        try Data(repeating: 2, count: 3).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = RuntimeStub(installed: true)
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: root,
            runtime: runtime
        )
        try await engine.preload()
        try await engine.delete()
        let status = await engine.status()

        #expect(!FileManager.default.fileExists(atPath: model.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(!status.loaded)
    }

    @Test
    func testInstalledModelTranscribesRealAudioWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let rootPath = environment["TIRO_COREML_TEST_MODEL_ROOT"],
            let audioPath = environment["TIRO_COREML_TEST_AUDIO"]
        else {
            return
        }
        let engine = CoreMLParakeetEngine(
            modelsRootDirectory: URL(fileURLWithPath: rootPath, isDirectory: true)
        )

        if environment["TIRO_COREML_TEST_DOWNLOAD"] == "1",
           !(await engine.status()).installed {
            try await engine.download()
        }
        try await engine.preload()
        let transcript = try await engine.transcribe(
            URL(fileURLWithPath: audioPath)
        )

        #expect(!transcript.text.isEmpty)
        #expect(transcript.model == .parakeetCompactCoreML)
        #expect(transcript.audioSeconds > 0)
        #expect(transcript.transcriptionSeconds > 0)
        #expect(transcript.timesFasterThanRealtime > 0)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor RuntimeStub: CompactCoreMLRuntime {
    private var installed: Bool
    private let downloadCreatesInstallation: Bool
    private let downloadThrowsCancellation: Bool
    private let sessionDelay: TimeInterval
    private(set) var downloadCount = 0
    private(set) var makeSessionCount = 0

    init(
        installed: Bool = false,
        downloadCreatesInstallation: Bool = false,
        downloadThrowsCancellation: Bool = false,
        sessionDelay: TimeInterval = 0
    ) {
        self.installed = installed
        self.downloadCreatesInstallation = downloadCreatesInstallation
        self.downloadThrowsCancellation = downloadThrowsCancellation
        self.sessionDelay = sessionDelay
    }

    func isInstalled(at directory: URL) -> Bool {
        installed
    }

    func download(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        downloadCount += 1
        progress(0.25)
        if downloadThrowsCancellation {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data().write(to: directory.appendingPathComponent("partial"))
            throw CancellationError()
        }
        progress(0.75)
        guard downloadCreatesInstallation else { return }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 12).write(
            to: directory.appendingPathComponent("model")
        )
        installed = true
    }

    func makeSession(from directory: URL) async throws -> any CompactCoreMLSession {
        makeSessionCount += 1
        if sessionDelay > 0 {
            try await Task.sleep(for: .seconds(sessionDelay))
        }
        return SessionStub()
    }
}

private actor SessionStub: CompactCoreMLSession {
    func transcribe(_ audioURL: URL) -> RuntimeTranscript {
        RuntimeTranscript(
            text: "Hello from Core ML.",
            audioSeconds: 4,
            transcriptionSeconds: 0.05,
            timesFasterThanRealtime: 80
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.withLock { storedValues }
    }

    func append(_ value: Double) {
        lock.withLock { storedValues.append(value) }
    }
}
