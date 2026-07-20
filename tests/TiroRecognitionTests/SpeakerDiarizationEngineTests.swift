import Foundation
import Testing
@testable import TiroRecognition

struct SpeakerDiarizationEngineTests {
    @Test
    func assignsWordsByGreatestOverlapAndGroupsConsecutiveSpeakers() {
        let segments = [
            transcriptSegment(
                words: [
                    word("Hello", 0, 0.4),
                    word("there,", 0.4, 0.8),
                    word("Janne.", 0.8, 1.2),
                ]
            )
        ]
        let diarization = SpeakerDiarizationResult(
            intervals: [
                SpeakerInterval(speakerID: "A", startSeconds: 0, endSeconds: 0.7),
                SpeakerInterval(speakerID: "B", startSeconds: 0.7, endSeconds: 1.3),
            ]
        )

        let aligned = SpeakerDiarizationEngine.align(segments, with: diarization)

        #expect(aligned.count == 2)
        #expect(aligned[0].speakerID == "A")
        #expect(aligned[0].text == "Hello there,")
        #expect(aligned[0].words.count == 2)
        #expect(aligned[1].speakerID == "B")
        #expect(aligned[1].text == "Janne.")
    }

    @Test
    func equalOverlapPrefersIntervalContainingWordMidpoint() {
        let segments = [
            transcriptSegment(words: [word("middle", 0, 2)])
        ]
        let diarization = SpeakerDiarizationResult(
            intervals: [
                SpeakerInterval(speakerID: "A", startSeconds: 0, endSeconds: 0.5),
                SpeakerInterval(speakerID: "B", startSeconds: 0.75, endSeconds: 1.25),
            ]
        )

        let aligned = SpeakerDiarizationEngine.align(segments, with: diarization)

        #expect(aligned.first?.speakerID == "B")
    }

    @Test
    func remainingTieUsesStableSpeakerID() {
        let segments = [
            transcriptSegment(words: [word("shared", 0, 1)])
        ]
        let diarization = SpeakerDiarizationResult(
            intervals: [
                SpeakerInterval(speakerID: "speaker-2", startSeconds: 0, endSeconds: 1),
                SpeakerInterval(speakerID: "speaker-1", startSeconds: 0, endSeconds: 1),
            ]
        )

        let aligned = SpeakerDiarizationEngine.align(segments, with: diarization)

        #expect(aligned.first?.speakerID == "speaker-1")
    }

    @Test
    func leavesWordsWithoutSpeakerOverlapUnlabelled() {
        let segments = [
            transcriptSegment(
                words: [
                    word("Before", 0, 0.5),
                    word("after", 2, 2.5),
                ]
            )
        ]
        let diarization = SpeakerDiarizationResult(
            intervals: [
                SpeakerInterval(speakerID: "A", startSeconds: 0, endSeconds: 0.5)
            ]
        )

        let aligned = SpeakerDiarizationEngine.align(segments, with: diarization)

        #expect(aligned.count == 2)
        #expect(aligned[0].speakerID == "A")
        #expect(aligned[1].speakerID == nil)
    }

    @Test
    func alignsUntimedWordlessSegmentAsOneUnit() {
        let segment = TranscriptSegment(
            text: "A complete segment",
            startSeconds: 3,
            endSeconds: 5
        )
        let diarization = SpeakerDiarizationResult(
            intervals: [
                SpeakerInterval(speakerID: "A", startSeconds: 2, endSeconds: 4),
                SpeakerInterval(speakerID: "B", startSeconds: 4, endSeconds: 6),
            ]
        )

        let aligned = SpeakerDiarizationEngine.align([segment], with: diarization)

        #expect(aligned.count == 1)
        #expect(aligned[0].text == segment.text)
        #expect(aligned[0].speakerID == "A")
        #expect(aligned[0].words.isEmpty)
    }

    @Test
    func engineUsesInjectedRuntime() async throws {
        let audioURL = URL(fileURLWithPath: "/tmp/meeting.wav")
        let runtime = RuntimeStub(
            result: SpeakerDiarizationResult(
                intervals: [
                    SpeakerInterval(speakerID: "A", startSeconds: 0, endSeconds: 1)
                ]
            )
        )
        let engine = SpeakerDiarizationEngine(runtime: runtime)

        let aligned = try await engine.diarize(
            audioURL,
            transcriptSegments: [
                transcriptSegment(words: [word("Hello", 0, 0.5)])
            ]
        )

        #expect(await runtime.receivedURL == audioURL)
        #expect(aligned.first?.speakerID == "A")
    }

    @Test
    func managedRuntimeStagesVerifiesAndLoadsOnlyFromFinalRoot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )

        try await managed.download()
        let installed = root.appendingPathComponent("speaker-diarization-coreml")
        #expect(FluidAudioOnDemandDiarizationRuntime.hasRequiredModelFiles(at: installed))
        #expect(try lifecycleArtifacts(at: root).isEmpty)

        _ = try await managed.diarize(URL(fileURLWithPath: "/tmp/meeting.wav"))
        #expect(await runtime.sessionRoots == [root.standardizedFileURL])
        let status = await managed.status()
        #expect(status.installed)
        #expect(status.loaded)
        #expect(status.downloadProgress == nil)
    }

    @Test
    func incompleteDownloadIsRejectedAndStagingIsRemoved() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .incomplete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )

        await #expect(throws: SpeakerDiarizationError.self) {
            try await managed.download()
        }

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("speaker-diarization-coreml").path
        ))
        #expect(try lifecycleArtifacts(at: root).isEmpty)
    }

    @Test
    func cancellationRemovesStagingDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .cancelled)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )

        await #expect(throws: CancellationError.self) {
            try await managed.download()
        }

        #expect(try lifecycleArtifacts(at: root).isEmpty)
    }

    @Test
    func insufficientCapacityPreventsDownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let available: Int64 = 100
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in available }
        )

        await #expect(throws: SpeakerDiarizationError.insufficientDiskSpace(
            requiredBytes: FluidAudioOnDemandDiarizationRuntime.expectedDownloadBytes
                + FluidAudioOnDemandDiarizationRuntime.minimumRemainingBytes,
            availableBytes: available
        )) {
            try await managed.download()
        }
        #expect(await runtime.downloadRoots.isEmpty)
    }

    @Test
    func incompleteInstalledDirectoryIsReplaced() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = root.appendingPathComponent(
            "speaker-diarization-coreml",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: incomplete,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: incomplete.appendingPathComponent("plda-parameters.json")
        )
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )

        try await managed.download()

        #expect(FluidAudioOnDemandDiarizationRuntime.hasRequiredModelFiles(
            at: incomplete
        ))
        #expect(try lifecycleArtifacts(at: root).isEmpty)
    }

    @Test
    func modelDirectoryLeasePreventsConcurrentMutation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try #require(ModelDirectoryLease.acquire(at: root))
        defer { lease.release() }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )

        await #expect(throws: SpeakerDiarizationError.modelStorageInUse) {
            try await managed.download()
        }
        #expect(await runtime.downloadRoots.isEmpty)
    }

    @Test
    func downloadReportsBoundedProgress() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )
        let recorder = ProgressRecorder()

        try await managed.download { recorder.append($0) }

        #expect(recorder.values == [0.5, 0.95, 1])
    }

    @Test
    func engineCleansAbandonedLifecycleArtifacts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = root.appendingPathComponent(
            ".diarization-download-abandoned",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: abandoned,
            withIntermediateDirectories: true
        )
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )
        let engine = SpeakerDiarizationEngine(runtime: managed)

        try await engine.cleanupAbandonedDownload()

        #expect(try lifecycleArtifacts(at: root).isEmpty)
    }

    @Test
    func deleteUnloadsAndRemovesInstalledModel() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DiarizationModelRuntimeStub(downloadBehavior: .complete)
        let managed = FluidAudioOnDemandDiarizationRuntime(
            modelsRootDirectory: root,
            runtime: runtime,
            availableCapacity: { _ in Int64.max }
        )
        try await managed.download()
        try await managed.load()
        try await managed.unload()
        #expect(!(await managed.status()).loaded)

        try await managed.delete()

        let status = await managed.status()
        #expect(!status.installed)
        #expect(!status.loaded)
    }

    private func transcriptSegment(words: [TranscriptWord]) -> TranscriptSegment {
        TranscriptSegment(
            text: words.map(\.text).joined(separator: " "),
            startSeconds: words.first?.startSeconds ?? 0,
            endSeconds: words.last?.endSeconds ?? 0,
            words: words
        )
    }

    private func word(
        _ text: String,
        _ startSeconds: Double,
        _ endSeconds: Double
    ) -> TranscriptWord {
        TranscriptWord(
            text: text,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tiro-diarization-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func lifecycleArtifacts(at root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".diarization-download-")
                || $0.hasPrefix(".diarization-installing-")
        }
    }
}

private actor RuntimeStub: SpeakerDiarizationRuntime {
    private let result: SpeakerDiarizationResult
    private(set) var receivedURL: URL?

    init(result: SpeakerDiarizationResult) {
        self.result = result
    }

    func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult {
        receivedURL = audioURL
        return result
    }
}

@available(macOS 14.0, *)
private actor DiarizationModelRuntimeStub: OfflineDiarizationModelRuntime {
    enum DownloadBehavior {
        case complete
        case incomplete
        case cancelled
    }

    let downloadBehavior: DownloadBehavior
    private(set) var downloadRoots: [URL] = []
    private(set) var sessionRoots: [URL] = []

    init(downloadBehavior: DownloadBehavior) {
        self.downloadBehavior = downloadBehavior
    }

    func isInstalled(at modelDirectory: URL) async -> Bool {
        FluidAudioOnDemandDiarizationRuntime.hasRequiredModelFiles(at: modelDirectory)
    }

    func download(
        to modelsRootDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        downloadRoots.append(modelsRootDirectory.standardizedFileURL)
        let modelDirectory = modelsRootDirectory.appendingPathComponent(
            "speaker-diarization-coreml",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        let names = downloadBehavior == .incomplete
            ? ["Segmentation.mlmodelc"]
            : requiredModelNames
        for name in names {
            let url = modelDirectory.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                try Data("compiled model".utf8).write(
                    to: url.appendingPathComponent("model.bin")
                )
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }
        progress(0.5)
        if downloadBehavior == .cancelled {
            throw CancellationError()
        }
        progress(1)
    }

    func makeSession(
        from modelsRootDirectory: URL
    ) async throws -> any OfflineDiarizationSession {
        sessionRoots.append(modelsRootDirectory.standardizedFileURL)
        return DiarizationSessionStub()
    }

    private var requiredModelNames: [String] {
        [
            "Segmentation.mlmodelc",
            "FBank.mlmodelc",
            "Embedding.mlmodelc",
            "PldaRho.mlmodelc",
            "plda-parameters.json",
        ]
    }
}

@available(macOS 14.0, *)
private struct DiarizationSessionStub: OfflineDiarizationSession {
    func diarize(_ audioURL: URL) async throws -> SpeakerDiarizationResult {
        SpeakerDiarizationResult(intervals: [])
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
