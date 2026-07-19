import Foundation
import Testing
@testable import TiroRecognition

@Suite(.serialized)
struct WhisperEngineTests {
    @Test
    func curatedCatalogHasStableExplicitSpecs() {
        #expect(WhisperModel.allCases == [
            .tinyEnglish,
            .baseEnglish,
            .smallEnglish,
            .tiny,
            .base,
            .small,
            .distilLargeV3,
            .largeV3,
            .turbo,
        ])
        #expect(WhisperModel.tinyEnglish.spec.variant == "openai_whisper-tiny.en")
        #expect(WhisperModel.baseEnglish.spec.variant == "openai_whisper-base.en")
        #expect(WhisperModel.smallEnglish.spec.variant == "openai_whisper-small.en")
        #expect(WhisperModel.tiny.spec.variant == "openai_whisper-tiny")
        #expect(WhisperModel.base.spec.variant == "openai_whisper-base")
        #expect(WhisperModel.small.spec.variant == "openai_whisper-small")
        #expect(
            WhisperModel.distilLargeV3.spec.variant
                == "distil-whisper_distil-large-v3_594MB"
        )
        #expect(WhisperModel.largeV3.spec.variant == "large-v3-v20240930_626MB")
        #expect(
            WhisperModel.turbo.spec.directoryName
                == "openai_whisper-large-v3-v20240930_turbo_632MB"
        )
        #expect(
            WhisperModel.largeV3.spec.repository
                == "argmaxinc/whisperkit-coreml"
        )
    }

    @Test
    func derivesCanonicalDirectoryFromConfiguredRoot() {
        let engine = CoreMLWhisperEngine(
            model: .small,
            modelsRootDirectory: URL(fileURLWithPath: "/tmp/tiro-whisper")
        )

        #expect(engine.modelsRootDirectory.path == "/tmp/tiro-whisper")
        #expect(
            engine.modelDirectory.path
                == "/tmp/tiro-whisper/openai_whisper-small"
        )
    }

    @Test
    func reportsMissingModelWithoutLoadingIt() async {
        let runtime = WhisperRuntimeStub()
        let engine = CoreMLWhisperEngine(
            model: .tiny,
            modelsRootDirectory: temporaryDirectory(),
            runtime: runtime
        )

        let status = await engine.status()

        #expect(!status.installed)
        #expect(!status.loaded)
        #expect(status.sizeBytes == 0)
        #expect(status.activity == .idle)
        #expect(await runtime.makeSessionCount == 0)
    }

    @Test
    func downloadPublishesBoundedProgressAndVerifiesInstallation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WhisperRuntimeStub(downloadCreatesInstallation: true)
        let engine = CoreMLWhisperEngine(
            model: .base,
            modelsRootDirectory: root,
            runtime: runtime
        )
        let progress = WhisperProgressRecorder()

        try await engine.download { progress.append($0) }
        let status = await engine.status()

        #expect(await runtime.downloadCount == 1)
        #expect(progress.values == [0, 0.5, 1, 1])
        #expect(status.installed)
        #expect(status.sizeBytes == 12)
        #expect(status.activity == .idle)
        #expect(status.downloadProgress == nil)
    }

    @Test
    func incompleteDownloadIsRejectedAndRecorded() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CoreMLWhisperEngine(
            model: .tiny,
            modelsRootDirectory: root,
            runtime: WhisperRuntimeStub(downloadCreatesInstallation: false)
        )

        do {
            try await engine.download()
            Issue.record("Expected an incomplete download error")
        } catch CoreMLWhisperError.downloadIncomplete(_) {
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
    func loadAndTranscribeUseOwnedSessionAndDecodingOptions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WhisperSessionStub()
        let runtime = WhisperRuntimeStub(installed: true, session: session)
        let engine = CoreMLWhisperEngine(
            model: .turbo,
            modelsRootDirectory: root,
            runtime: runtime
        )
        let options = WhisperDecodingOptions(
            language: " FR ",
            task: .translate
        )

        try await engine.load()
        let transcript = try await engine.transcribe(
            URL(fileURLWithPath: "/tmp/voice.wav"),
            options: options
        )

        #expect(await runtime.makeSessionCount == 1)
        #expect(await session.lastOptions == options)
        #expect(transcript.text == "Hello from WhisperKit.")
        #expect(transcript.model == .turbo)
        #expect(transcript.language == "fr")
        #expect(transcript.audioSeconds == 4)
        #expect(transcript.transcriptionSeconds == 0.1)
        #expect(transcript.timesFasterThanRealtime == 40)
        #expect((await engine.status()).loaded)
    }

    @Test
    func emptyLanguageSelectsAutomaticDetection() {
        #expect(WhisperDecodingOptions(language: "  ").language == nil)
        #expect(WhisperDecodingOptions(language: nil).language == nil)
        #expect(WhisperDecodingOptions(language: "EN").language == "en")
    }

    @Test
    func concurrentLoadsJoinOneRuntimeLoad() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WhisperRuntimeStub(
            installed: true,
            sessionDelay: 0.05
        )
        let engine = CoreMLWhisperEngine(
            model: .small,
            modelsRootDirectory: root,
            runtime: runtime
        )

        async let first: Void = engine.load()
        async let second: Void = engine.load()
        _ = try await (first, second)

        #expect(await runtime.makeSessionCount == 1)
        #expect((await engine.status()).loaded)
    }

    @Test
    func unloadReleasesRuntimeSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WhisperSessionStub()
        let engine = CoreMLWhisperEngine(
            model: .tiny,
            modelsRootDirectory: root,
            runtime: WhisperRuntimeStub(installed: true, session: session)
        )

        try await engine.load()
        try await engine.unload()

        #expect(await session.unloadCount == 1)
        #expect(!(await engine.status()).loaded)
    }

    @Test
    func transcribeRequiresLoadedModel() async {
        let engine = CoreMLWhisperEngine(
            model: .tiny,
            modelsRootDirectory: temporaryDirectory(),
            runtime: WhisperRuntimeStub(installed: true)
        )

        do {
            _ = try await engine.transcribe(
                URL(fileURLWithPath: "/tmp/voice.wav")
            )
            Issue.record("Expected a model-not-loaded error")
        } catch CoreMLWhisperError.modelNotLoaded {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func deleteRemovesOnlySelectedModelAndUnloadsIt() async throws {
        let root = temporaryDirectory()
        let modelDirectory = root.appendingPathComponent(
            WhisperModel.base.spec.directoryName,
            isDirectory: true
        )
        let sibling = root.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 4).write(
            to: modelDirectory.appendingPathComponent("model")
        )
        try Data(repeating: 2, count: 3).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WhisperSessionStub()
        let engine = CoreMLWhisperEngine(
            model: .base,
            modelsRootDirectory: root,
            runtime: WhisperRuntimeStub(installed: true, session: session)
        )

        try await engine.load()
        try await engine.delete()

        #expect(!FileManager.default.fileExists(atPath: modelDirectory.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(await session.unloadCount == 1)
        #expect(!(await engine.status()).loaded)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor WhisperRuntimeStub: WhisperCoreMLRuntime {
    private var installed: Bool
    private let downloadCreatesInstallation: Bool
    private let session: WhisperSessionStub
    private let sessionDelay: TimeInterval
    private(set) var downloadCount = 0
    private(set) var makeSessionCount = 0

    init(
        installed: Bool = false,
        downloadCreatesInstallation: Bool = false,
        session: WhisperSessionStub = WhisperSessionStub(),
        sessionDelay: TimeInterval = 0
    ) {
        self.installed = installed
        self.downloadCreatesInstallation = downloadCreatesInstallation
        self.session = session
        self.sessionDelay = sessionDelay
    }

    func isInstalled(model: WhisperModelSpec, at directory: URL) -> Bool {
        installed
    }

    func download(
        model: WhisperModelSpec,
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        downloadCount += 1
        progress(-0.5)
        progress(0.5)
        progress(1.5)
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

    func makeSession(
        model: WhisperModelSpec,
        from directory: URL
    ) async throws -> any WhisperCoreMLSession {
        makeSessionCount += 1
        if sessionDelay > 0 {
            try await Task.sleep(for: .seconds(sessionDelay))
        }
        return session
    }
}

private actor WhisperSessionStub: WhisperCoreMLSession {
    private(set) var lastOptions: WhisperDecodingOptions?
    private(set) var unloadCount = 0

    func transcribe(
        _ audioURL: URL,
        options: WhisperDecodingOptions
    ) -> WhisperRuntimeTranscript {
        lastOptions = options
        return WhisperRuntimeTranscript(
            text: "Hello from WhisperKit.",
            language: options.language ?? "en",
            audioSeconds: 4,
            transcriptionSeconds: 0.1,
            timesFasterThanRealtime: 40
        )
    }

    func unload() {
        unloadCount += 1
    }
}

private final class WhisperProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.withLock { storedValues }
    }

    func append(_ value: Double) {
        lock.withLock { storedValues.append(value) }
    }
}
