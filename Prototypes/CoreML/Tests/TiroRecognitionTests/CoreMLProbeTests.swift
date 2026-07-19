import CoreML
import FluidAudio
import Foundation
import Testing
@testable import TiroRecognition

struct CoreMLProbeTests {
    @Test
    func testParsesExplicitAudioModelDirectoryAndDownload() throws {
        let options = try CoreMLProbeOptions.parse(
            arguments: [
                "--audio", "/tmp/voice.wav",
                "--model-dir", "/tmp/coreml",
                "--download",
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        #expect(options.audioURL.path == "/tmp/voice.wav")
        #expect(
            options.modelDirectory.path
                == "/tmp/coreml/parakeet-tdt-ctc-110m"
        )
        #expect(options.allowDownload)
    }

    @Test
    func testDefaultsToTiroSpecificCoreMLDirectoryWithoutDownloading() throws {
        let options = try CoreMLProbeOptions.parse(
            arguments: ["--audio", "/tmp/voice.wav"],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        #expect(
            options.modelDirectory.path
                == "/Users/test/Library/Application Support/Tiro/Models/coreml-prototype/parakeet-tdt-ctc-110m"
        )
        #expect(!options.allowDownload)
    }

    @Test
    func testRejectsMissingAudio() {
        #expect(throws: CoreMLProbeOptionError.missingAudio) {
            try CoreMLProbeOptions.parse(arguments: [])
        }
    }

    @Test
    func testDirectorySizeCountsRegularFilesRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("one"))
        try Data(repeating: 2, count: 11).write(to: nested.appendingPathComponent("two"))

        #expect(DirectorySize.bytes(at: root) == 18)
    }

    @Test
    func prepareWithoutDownloadNeverCallsModelDownload() async {
        let access = ModelAccessStub(modelExists: false)
        let directory = URL(fileURLWithPath: "/tmp/coreml/parakeet-tdt-ctc-110m")
        let engine = CoreMLParakeetEngine(
            modelDirectory: directory,
            modelAccess: access
        )

        await #expect(throws: CoreMLParakeetError.self) {
            _ = try await engine.prepare(
                model: .parakeetCompactCoreML,
                allowDownload: false
            )
        }
        #expect(await access.downloadCount == 0)
        #expect(await access.loadCount == 0)
    }

    @Test
    func failedDownloadRestoresOfflineMode() async {
        ModelHub.offlineMode = true

        await #expect(throws: ModelAccessStubError.self) {
            _ = try await FluidAudioModelAccess.withNetworkAccess {
                #expect(!ModelHub.offlineMode)
                throw ModelAccessStubError.downloadFailed
            }
        }

        #expect(ModelHub.offlineMode)
    }
}

private actor ModelAccessStub: CoreMLModelAccess {
    private(set) var downloadCount = 0
    private(set) var loadCount = 0
    private let modelExists: Bool

    init(modelExists: Bool) {
        self.modelExists = modelExists
    }

    func compactModelExists(at directory: URL) -> Bool {
        modelExists
    }

    func downloadCompactModel(to directory: URL) {
        downloadCount += 1
    }

    func loadCompactModelOffline(
        from directory: URL,
        configuration: MLModelConfiguration
    ) throws -> AsrModels {
        loadCount += 1
        throw ModelAccessStubError.unexpectedLoad
    }
}

private enum ModelAccessStubError: Error {
    case downloadFailed
    case unexpectedLoad
}
