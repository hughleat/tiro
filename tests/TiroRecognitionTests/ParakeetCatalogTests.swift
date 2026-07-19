import Foundation
import FluidAudio
import Testing
@testable import TiroRecognition

@Suite(.serialized)
struct ParakeetCatalogTests {
    @Test
    func catalogHasStableIdentityAndSeparateDirectories() {
        #expect(ParakeetModel.allCases == [.compact, .v2, .v3])
        #expect(ParakeetModel.compact.recognitionModel == .parakeetCompactCoreML)
        #expect(ParakeetModel.v2.recognitionModel == .parakeetV2CoreML)
        #expect(ParakeetModel.v3.recognitionModel == .parakeetV3CoreML)

        let directoryNames = Set(ParakeetModel.allCases.map(\.directoryName))
        #expect(directoryNames.count == ParakeetModel.allCases.count)
        #expect(
            ParakeetModel.compact.directoryName
                == CoreMLParakeetEngine.canonicalDirectoryName
        )
    }

    @Test(arguments: ParakeetModel.allCases)
    func engineUsesSelectedModelDirectoryAndTranscriptIdentity(
        model: ParakeetModel
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CoreMLParakeetEngine(
            model: model,
            modelsRootDirectory: root,
            runtime: CatalogRuntimeStub()
        )

        try await engine.preload()
        let transcript = try await engine.transcribe(
            URL(fileURLWithPath: "/tmp/catalog.wav")
        )

        #expect(engine.model == model)
        #expect(
            engine.modelDirectory.path
                == root.appendingPathComponent(model.directoryName).path
        )
        #expect(transcript.model == model.recognitionModel)
    }

    @Test
    func modelLifecyclesRemainIndependent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let compact = CoreMLParakeetEngine(
            model: .compact,
            modelsRootDirectory: root,
            runtime: CatalogRuntimeStub()
        )
        let multilingual = CoreMLParakeetEngine(
            model: .v3,
            modelsRootDirectory: root,
            runtime: CatalogRuntimeStub()
        )

        async let compactLoad: Void = compact.preload()
        async let multilingualLoad: Void = multilingual.preload()
        _ = try await (compactLoad, multilingualLoad)
        try await compact.unload()

        #expect(!(await compact.status()).loaded)
        #expect((await multilingual.status()).loaded)
        #expect(compact.modelDirectory != multilingual.modelDirectory)
    }

    @Test(arguments: ParakeetModel.allCases)
    func eachModelSupportsTheCompleteLifecycle(
        model: ParakeetModel
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CatalogLifecycleRuntime()
        let engine = CoreMLParakeetEngine(
            model: model,
            modelsRootDirectory: root,
            runtime: runtime
        )

        #expect(!(await engine.status()).installed)
        try await engine.download()
        #expect((await engine.status()).installed)

        try await engine.preload()
        #expect((await engine.status()).loaded)
        let transcript = try await engine.transcribe(
            URL(fileURLWithPath: "/tmp/catalog.wav")
        )
        #expect(transcript.model == model.recognitionModel)

        try await engine.delete()
        let deletedStatus = await engine.status()
        #expect(!deletedStatus.installed)
        #expect(!deletedStatus.loaded)
    }

    @Test
    func fluidAudioGlobalBackendAccessIsSerializedAndRestored() async throws {
        let originalMode = ModelHub.offlineMode
        let probe = ConcurrencyProbe()

        async let first: Void = FluidAudioRuntime.withNetworkAccess {
            await probe.enter()
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        async let second: Void = FluidAudioRuntime.withNetworkAccess {
            await probe.enter()
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        _ = try await (first, second)

        #expect(await probe.maximumConcurrentOperations == 1)
        #expect(ModelHub.offlineMode == originalMode)
    }
}

private actor CatalogRuntimeStub: CompactCoreMLRuntime {
    func isInstalled(at directory: URL) -> Bool {
        true
    }

    func download(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) {}

    func makeSession(
        from directory: URL
    ) -> any CompactCoreMLSession {
        CatalogSessionStub()
    }
}

private actor CatalogSessionStub: CompactCoreMLSession {
    func transcribe(_ audioURL: URL) -> RuntimeTranscript {
        RuntimeTranscript(
            text: "Catalog transcript",
            audioSeconds: 1,
            transcriptionSeconds: 0.1,
            timesFasterThanRealtime: 10
        )
    }
}

private actor CatalogLifecycleRuntime: CompactCoreMLRuntime {
    func isInstalled(at directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("model").path
        )
    }

    func download(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: directory.appendingPathComponent("model"))
        progress(1)
    }

    func makeSession(
        from directory: URL
    ) -> any CompactCoreMLSession {
        CatalogSessionStub()
    }
}

private actor ConcurrencyProbe {
    private var concurrentOperations = 0
    private(set) var maximumConcurrentOperations = 0

    func enter() {
        concurrentOperations += 1
        maximumConcurrentOperations = max(
            maximumConcurrentOperations,
            concurrentOperations
        )
    }

    func leave() {
        concurrentOperations -= 1
    }
}
