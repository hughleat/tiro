import Foundation
import Testing
import TiroRecognition
@testable import Tiro

@Suite(.serialized)
struct NativeTiroStoreTests {
    @Test
    func newInstallIsPrivateByDefaultAndUsesPrivatePermissions() async throws {
        try await withStore { store, root in
            let settings = try await store.privacySettings()
            #expect(settings == .newInstall)

            let attributes = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent("privacy.json").path
            )
            #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
        }
    }

    @Test
    func finalizationPersistsCompatibleJSONAndAudio() async throws {
        try await withStore { store, root in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: true,
                retentionDays: 0
            ))
            try await store.saveVocabulary([
                NativeVocabularyEntry(spoken: "yana", written: "Janne"),
            ])
            _ = try await store.saveSnippet(NativeSnippet(
                id: "signature",
                trigger: "my signature",
                content: "Best regards"
            ))

            let entry = try await store.finalize(NativeFinalizationRequest(
                rawText: "yana my signature",
                modelID: "parakeet-tdt-ctc-110m-coreml",
                transcriptionSeconds: 0.1236,
                audio: Data("wav".utf8),
                originBundleID: "com.example.editor",
                originAppName: "Editor",
                segments: [TranscriptSegment(
                    text: "Janne Best regards",
                    startSeconds: 0,
                    endSeconds: 1.2,
                    speakerID: "speaker-0"
                )],
                id: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
            ))

            #expect(entry.text == "Janne Best regards")
            #expect(entry.rawText == "yana my signature")
            #expect(entry.transcriptionSeconds == 0.124)
            #expect(entry.segments?.first?.speakerID == "speaker-0")
            #expect(entry.audioFile?.hasPrefix("\(root.lastPathComponent)/audio/") == true)
            #expect(try await store.audio(forHistoryID: entry.id) == Data("wav".utf8))

            let persisted = try String(
                contentsOf: root.appendingPathComponent("history.jsonl"),
                encoding: .utf8
            )
            #expect(persisted.contains(#""origin_bundle_id":"com.example.editor""#))
            #expect(persisted.contains(#""raw_text":"yana my signature""#))
        }
    }

    @Test
    func disabledHistoryReturnsTextWithoutWritingPrivateContent() async throws {
        try await withStore { store, root in
            let entry = try await store.finalize(NativeFinalizationRequest(
                rawText: "hello",
                modelID: "model",
                transcriptionSeconds: 0.1,
                audio: Data("secret".utf8)
            ))

            #expect(entry.text == "hello")
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("history.jsonl").path
            ))
            #expect((try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("audio"),
                includingPropertiesForKeys: nil
            )).isEmpty)
        }
    }

    @Test
    func individualJobCanAvoidHistoryAndRetainSourceMetadataInItsResult() async throws {
        try await withStore { store, root in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: true,
                retentionDays: 0
            ))
            let entry = try await store.finalize(NativeFinalizationRequest(
                rawText: "meeting notes",
                modelID: "model",
                transcriptionSeconds: 0.2,
                audio: Data("audio".utf8),
                sourceFilename: "meeting.m4a",
                saveToHistory: false
            ))

            #expect(entry.sourceFilename == "meeting.m4a")
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("history.jsonl").path
            ))
            #expect((try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("audio"),
                includingPropertiesForKeys: nil
            )).isEmpty)
        }
    }

    @Test
    func cancelledFinalizationDoesNotPersistHistoryOrAudio() async throws {
        try await withStore { store, root in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: true,
                retentionDays: 0
            ))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.finalize(NativeFinalizationRequest(
                    rawText: "cancelled",
                    modelID: "model",
                    transcriptionSeconds: 0.1,
                    audio: Data("private audio".utf8)
                ))
            }

            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("history.jsonl").path
            ))
            #expect((try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("audio"),
                includingPropertiesForKeys: nil
            )).isEmpty)
        }
    }

    @Test
    func profileVocabularyOverridesGlobalVocabulary() async throws {
        try await withStore { store, _ in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: false,
                retentionDays: 0
            ))
            try await store.saveVocabulary([
                NativeVocabularyEntry(spoken: "yana", written: "Global"),
            ])
            try await store.saveVocabularyProfiles(NativeVocabularyProfilesDocument(
                profiles: [NativeVocabularyProfile(
                    bundleID: "com.example.editor",
                    name: "Editor",
                    entries: [NativeVocabularyEntry(spoken: "Yana", written: "Janne")]
                )]
            ))

            let entry = try await store.finalize(NativeFinalizationRequest(
                rawText: "yana",
                modelID: "model",
                transcriptionSeconds: 0.1,
                originBundleID: "com.example.editor"
            ))
            #expect(entry.text == "Janne")
        }
    }

    @Test
    func retentionDeletesExpiredHistoryAndItsRecording() async throws {
        try await withStore { store, root in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: true,
                retentionDays: 0
            ))
            let now = Date(timeIntervalSince1970: 2_000_000)
            let old = try await store.finalize(NativeFinalizationRequest(
                rawText: "old",
                modelID: "model",
                transcriptionSeconds: 0.1,
                audio: Data("old".utf8),
                timestamp: now.addingTimeInterval(-8 * 86_400)
            ))
            _ = try await store.finalize(NativeFinalizationRequest(
                rawText: "new",
                modelID: "model",
                transcriptionSeconds: 0.1,
                audio: Data("new".utf8),
                timestamp: now
            ))

            #expect(try await store.applyRetention(days: 7, now: now) == 1)
            #expect(try await store.searchHistory().map(\.text) == ["new"])
            let oldAudio = root.deletingLastPathComponent()
                .appendingPathComponent(old.audioFile!)
            #expect(!FileManager.default.fileExists(atPath: oldAudio.path))
        }
    }

    @Test
    func repeatedCorrectionsCreateAndAcceptVocabularySuggestion() async throws {
        try await withStore { store, _ in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: false,
                retentionDays: 0
            ))
            for id in [
                UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            ] {
                let entry = try await store.finalize(NativeFinalizationRequest(
                    rawText: "hello yana",
                    modelID: "model",
                    transcriptionSeconds: 0.1,
                    id: id
                ))
                #expect(try await store.correctHistoryEntry(
                    id: entry.id,
                    correctedText: "hello Janne"
                ))
            }

            let suggestions = try await store.suggestions()
            #expect(suggestions.count == 1)
            #expect(suggestions[0].spoken == "yana")
            #expect(suggestions[0].written == "Janne")
            #expect(suggestions[0].count == 2)
            #expect(try await store.acceptSuggestion(
                id: suggestions[0].id,
                scope: .global
            ) == .global)
            #expect(try await store.vocabulary().contains(
                NativeVocabularyEntry(spoken: "yana", written: "Janne")
            ))
            #expect(try await store.suggestions().isEmpty)
        }
    }

    @Test
    func deletingHistoryAlsoDeletesUnreferencedAudioAndSuggestionEvidence() async throws {
        try await withStore { store, root in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: true,
                retentionDays: 0
            ))
            let entry = try await store.finalize(NativeFinalizationRequest(
                rawText: "hello",
                modelID: "model",
                transcriptionSeconds: 0.1,
                audio: Data("wav".utf8)
            ))
            let audio = root.deletingLastPathComponent().appendingPathComponent(entry.audioFile!)

            #expect(try await store.deleteHistoryEntry(id: entry.id))
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            #expect(try await store.searchHistory().isEmpty)
        }
    }

    @Test
    func malformedHistoryBlocksMutationWithoutDroppingExistingLines() async throws {
        try await withStore { store, root in
            let history = root.appendingPathComponent("history.jsonl")
            let original = #"{"id":"valid","timestamp":"now","model":"model","transcription_seconds":0.1,"text":"hello"}"# +
                "\nnot-json\n"
            try original.write(to: history, atomically: true, encoding: .utf8)

            await #expect(throws: NativeStoreError.self) {
                _ = try await store.finalize(NativeFinalizationRequest(
                    rawText: "new",
                    modelID: "model",
                    transcriptionSeconds: 0.1
                ))
            }
            #expect(try String(contentsOf: history, encoding: .utf8) == original)
        }
    }

    @Test
    func audioReferencesCannotEscapeThroughSymlinkedAncestors() async throws {
        try await withStore { store, root in
            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("TiroOutside-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.wav"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("audio/link"),
                withDestinationURL: outside
            )
            let entry = NativeHistoryEntry(
                id: "entry",
                timestamp: "2026-01-01T00:00:00Z",
                model: "model",
                transcriptionSeconds: 0.1,
                text: "hello",
                audioFile: "\(root.lastPathComponent)/audio/link/secret.wav"
            )
            var data = try JSONEncoder().encode(entry)
            data.append(0x0A)
            try data.write(to: root.appendingPathComponent("history.jsonl"))

            await #expect(throws: NativeStoreError.self) {
                _ = try await store.audio(forHistoryID: "entry")
            }
        }
    }

    @Test
    func retentionDoesNotDependOnSuggestionFileHealth() async throws {
        try await withStore { store, root in
            _ = try await store.updatePrivacySettings(NativePrivacySettings(
                storeHistory: true,
                storeRecordings: true,
                retentionDays: 0
            ))
            let now = Date(timeIntervalSince1970: 2_000_000)
            let entry = try await store.finalize(NativeFinalizationRequest(
                rawText: "old",
                modelID: "model",
                transcriptionSeconds: 0.1,
                audio: Data("wav".utf8),
                timestamp: now.addingTimeInterval(-8 * 86_400)
            ))
            let audio = root.deletingLastPathComponent().appendingPathComponent(entry.audioFile!)
            try Data("malformed".utf8).write(to: root.appendingPathComponent("suggestions.json"))

            #expect(try await store.applyRetention(days: 7, now: now) == 1)
            #expect(try await store.searchHistory().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: audio.path))
        }
    }

    private func withStore(
        _ body: (NativeTiroStore, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiroNativeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NativeTiroStore(rootURL: root)
        try await body(store, root)
    }
}
