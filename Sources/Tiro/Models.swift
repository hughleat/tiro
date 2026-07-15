import Foundation

struct DictationModel: Hashable {
    let key: String
    let name: String
    let detail: String

    static let all: [DictationModel] = [
        .init(key: "compact", name: "Parakeet Compact", detail: "English · 437 MB"),
        .init(key: "parakeet-v2", name: "Parakeet 0.6B v2", detail: "English · 2.3 GB"),
        .init(key: "qwen", name: "Qwen3-ASR 0.6B", detail: "Multilingual · 681 MB")
    ]

    static var selected: DictationModel {
        let key = UserDefaults.standard.string(forKey: "selectedModel") ?? "compact"
        return all.first(where: { $0.key == key }) ?? all[0]
    }

    static func select(_ model: DictationModel) {
        UserDefaults.standard.set(model.key, forKey: "selectedModel")
    }
}

struct HistoryEntry: Codable {
    let id: String
    let timestamp: String
    let model: String
    let transcription_seconds: Double
    let text: String
    let raw_text: String?
    let corrected_text: String?
    let origin_bundle_id: String?
    let origin_app_name: String?
    let audio_available: Bool

    var displayText: String { corrected_text ?? text }

    private let audio_file: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case model
        case audio_file
        case transcription_seconds
        case text
        case raw_text
        case corrected_text
        case origin_bundle_id
        case origin_bundle
        case origin_app_name
        case origin_name
        case audio_available
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        transcription_seconds = try values.decodeIfPresent(Double.self, forKey: .transcription_seconds) ?? 0
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        raw_text = try values.decodeIfPresent(String.self, forKey: .raw_text)
        corrected_text = try values.decodeIfPresent(String.self, forKey: .corrected_text)
        origin_bundle_id = try values.decodeIfPresent(String.self, forKey: .origin_bundle_id)
            ?? values.decodeIfPresent(String.self, forKey: .origin_bundle)
        let encodedOriginName = try values.decodeIfPresent(String.self, forKey: .origin_app_name)
            ?? values.decodeIfPresent(String.self, forKey: .origin_name)
        origin_app_name = encodedOriginName?.removingPercentEncoding ?? encodedOriginName
        audio_file = try values.decodeIfPresent(String.self, forKey: .audio_file)
        audio_available = try values.decodeIfPresent(Bool.self, forKey: .audio_available)
            ?? !(audio_file ?? "").isEmpty
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? audio_file
            ?? [timestamp, model, text].joined(separator: "|")
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(model, forKey: .model)
        try values.encode(transcription_seconds, forKey: .transcription_seconds)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(raw_text, forKey: .raw_text)
        try values.encodeIfPresent(corrected_text, forKey: .corrected_text)
        try values.encodeIfPresent(origin_bundle_id, forKey: .origin_bundle_id)
        try values.encodeIfPresent(origin_app_name, forKey: .origin_app_name)
        try values.encode(audio_available, forKey: .audio_available)
        try values.encodeIfPresent(audio_file, forKey: .audio_file)
    }
}

enum VocabularyFile {
    static let initialEntries = [
        VocabularyEntry(spoken: "yarna", written: "Janne"),
        VocabularyEntry(spoken: "yana", written: "Janne"),
        VocabularyEntry(spoken: "jana", written: "Janne")
    ]

    static func load(from url: URL = AppPaths.vocabularyFile) throws -> [VocabularyEntry] {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(VocabularyDocument.self, from: data).entries
        }
        if url == AppPaths.vocabularyFile,
           FileManager.default.fileExists(atPath: AppPaths.legacyVocabularyFile.path) {
            let text = try String(contentsOf: AppPaths.legacyVocabularyFile, encoding: .utf8)
            let entries = parseLegacy(text)
            try save(entries, to: url)
            return entries
        }
        try save(initialEntries, to: url)
        return initialEntries
    }

    static func save(_ entries: [VocabularyEntry], to url: URL = AppPaths.vocabularyFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(VocabularyDocument(entries: entries)).write(to: url, options: .atomic)
    }

    private static func parseLegacy(_ text: String) -> [VocabularyEntry] {
        var entries: [VocabularyEntry] = []
        var indexBySpoken: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let spoken = parts[0].trimmingCharacters(in: .whitespaces)
            let written = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard !spoken.isEmpty || !written.isEmpty else { continue }
            let key = VocabularyEntry.normalized(spoken)
            if let index = indexBySpoken[key] {
                entries[index].written = written
            } else {
                indexBySpoken[key] = entries.count
                entries.append(VocabularyEntry(spoken: spoken, written: written))
            }
        }
        return entries
    }
}

private struct VocabularyDocument: Codable {
    let entries: [VocabularyEntry]
}

struct VocabularyEntry: Codable, Equatable {
    var spoken: String
    var written: String

    static func normalized(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil)
    }
}

struct VocabularyProfilesDocument: Codable, Equatable {
    var version: Int
    var profiles: [VocabularyProfile]

    init(version: Int = 1, profiles: [VocabularyProfile] = []) {
        self.version = version
        self.profiles = profiles
    }
}

struct VocabularyProfile: Codable, Equatable {
    var bundle_id: String
    var name: String
    var entries: [VocabularyEntry]

    var displayBundleID: String { bundle_id.removingPercentEncoding ?? bundle_id }
    var displayName: String { name.removingPercentEncoding ?? name }
}

struct VocabularySuggestion: Decodable {
    let id: String
    let spoken: String
    let written: String
    let origin_bundle_id: String?
    let origin_app_name: String?
    let count: Int

    var displayBundleID: String? {
        origin_bundle_id.flatMap { $0.removingPercentEncoding ?? $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case spoken
        case written
        case bundle_id
        case origin_bundle_id
        case origin_app_name
        case name
        case origin_name
        case count
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        spoken = try values.decodeIfPresent(String.self, forKey: .spoken) ?? ""
        written = try values.decodeIfPresent(String.self, forKey: .written) ?? ""
        origin_bundle_id = try values.decodeIfPresent(String.self, forKey: .bundle_id)
            ?? values.decodeIfPresent(String.self, forKey: .origin_bundle_id)
        let encodedOriginName = try values.decodeIfPresent(String.self, forKey: .origin_app_name)
            ?? values.decodeIfPresent(String.self, forKey: .name)
            ?? values.decodeIfPresent(String.self, forKey: .origin_name)
        origin_app_name = encodedOriginName?.removingPercentEncoding ?? encodedOriginName
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}

struct TranscriptionResponse: Decodable {
    let timestamp: String
    let model: String
    let audio_file: String
    let transcription_seconds: Double
    let text: String
    let origin_bundle_id: String?
    let origin_app_name: String?
}

struct ErrorResponse: Decodable {
    let error: String
}
