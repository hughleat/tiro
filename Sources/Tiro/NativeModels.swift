import Foundation
import TiroRecognition

enum NativeStoreError: LocalizedError {
    case invalidData(String)
    case unsafePath(URL)
    case missingHistoryEntry
    case missingSuggestion

    var errorDescription: String? {
        switch self {
        case .invalidData(let message): message
        case .unsafePath(let url): "Tiro refused to use the unsafe path \(url.path)."
        case .missingHistoryEntry: "The transcription no longer exists."
        case .missingSuggestion: "The vocabulary suggestion no longer exists."
        }
    }
}

enum NativeDictationMode: String, Codable, CaseIterable, Sendable {
    case standard
    case verbatim
}

enum NativePunctuationMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case spoken
    case none
}

enum NativeSuggestionScope: String, Codable, Sendable {
    case global
    case profile
}

struct NativeTranscriptionOptions: Codable, Equatable, Sendable {
    var mode: NativeDictationMode = .standard
    var punctuation: NativePunctuationMode = .automatic
    var language = "English"
}

struct NativePrivacySettings: Codable, Equatable, Sendable {
    static let allowedRetentionDays = [0, 1, 7, 30, 90]
    static let newInstall = NativePrivacySettings(
        storeHistory: false,
        storeRecordings: false,
        retentionDays: 30
    )

    var storeHistory: Bool
    var storeRecordings: Bool
    var retentionDays: Int

    enum CodingKeys: String, CodingKey {
        case storeHistory = "store_history"
        case storeRecordings = "store_recordings"
        case retentionDays = "retention_days"
    }

    func validated() throws -> Self {
        guard Self.allowedRetentionDays.contains(retentionDays) else {
            throw NativeStoreError.invalidData("Retention must be 0, 1, 7, 30, or 90 days.")
        }
        guard storeHistory || !storeRecordings else {
            throw NativeStoreError.invalidData("Storing recordings requires history.")
        }
        return self
    }
}

struct NativeVocabularyEntry: Codable, Equatable, Hashable, Sendable {
    var spoken: String
    var written: String

    func validated() throws -> Self {
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, spoken.count <= 200,
              !written.isEmpty, written.count <= 500 else {
            throw NativeStoreError.invalidData(
                "Vocabulary entries need bounded, non-empty spoken and written text."
            )
        }
        return Self(spoken: spoken, written: written)
    }
}

struct NativeVocabularyDocument: Codable, Equatable, Sendable {
    var entries: [NativeVocabularyEntry] = []
}

struct NativeVocabularyProfile: Codable, Equatable, Sendable {
    var bundleID: String
    var name: String
    var entries: [NativeVocabularyEntry]

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case entries
    }
}

struct NativeVocabularyProfilesDocument: Codable, Equatable, Sendable {
    var version = 1
    var profiles: [NativeVocabularyProfile] = []
}

struct NativeSnippet: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var trigger: String
    var content: String
}

struct NativeSnippetsDocument: Codable, Equatable, Sendable {
    var version = 1
    var snippets: [NativeSnippet] = []
}

struct NativeHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: String
    var model: String
    var transcriptionSeconds: Double
    var text: String
    var mode: NativeDictationMode?
    var punctuation: NativePunctuationMode?
    var language: String?
    var rawText: String?
    var correctedText: String?
    var originBundleID: String?
    var originAppName: String?
    var sourceFilename: String?
    var audioFile: String?
    var audioAvailable: Bool?
    var segments: [TranscriptSegment]? = nil

    var displayText: String { correctedText ?? text }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case model
        case transcriptionSeconds = "transcription_seconds"
        case text
        case mode
        case punctuation
        case language
        case rawText = "raw_text"
        case correctedText = "corrected_text"
        case originBundleID = "origin_bundle_id"
        case originAppName = "origin_app_name"
        case sourceFilename = "source_filename"
        case audioFile = "audio_file"
        case audioAvailable = "audio_available"
        case segments
    }
}

struct NativeFinalizationRequest: Sendable {
    var rawText: String
    var recognizedText: String? = nil
    var modelID: String
    var transcriptionSeconds: Double
    var audio: Data?
    var originBundleID: String?
    var originAppName: String?
    var sourceFilename: String?
    var saveToHistory = true
    var textIsFinalized = false
    var segments: [TranscriptSegment] = []
    var options = NativeTranscriptionOptions()
    var timestamp = Date()
    var id = UUID()
}

struct NativeVocabularySuggestion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var spoken: String
    var written: String
    var originBundleID: String
    var originAppName: String
    var transcriptionIDs: [String]
    var count: Int
    var accepted: Bool
    var dismissed: Bool
    var acceptedScope: NativeSuggestionScope?
    var acceptingScope: NativeSuggestionScope?

    enum CodingKeys: String, CodingKey {
        case id
        case spoken
        case written
        case originBundleID = "origin_bundle_id"
        case originAppName = "origin_app_name"
        case transcriptionIDs = "transcription_ids"
        case count
        case accepted
        case dismissed
        case acceptedScope = "accepted_scope"
        case acceptingScope = "accepting_scope"
    }
}

struct NativeSuggestionsDocument: Codable, Equatable, Sendable {
    var version = 1
    var suggestions: [NativeVocabularySuggestion] = []
}
