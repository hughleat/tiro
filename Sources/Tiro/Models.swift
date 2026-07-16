import Foundation

enum DictationMode: String, CaseIterable {
    case standard
    case verbatim

    var title: String { rawValue.capitalized }
}

enum PunctuationMode: String, CaseIterable {
    case automatic
    case spoken
    case none

    var title: String { rawValue.capitalized }
}

enum DictationLanguage: String, CaseIterable {
    case auto
    case english
    case cantonese
    case arabic
    case french
    case german
    case spanish
    case italian
    case portuguese
    case dutch
    case chinese
    case japanese
    case korean
    case russian
    case indonesian
    case thai
    case vietnamese
    case turkish
    case hindi
    case malay
    case swedish
    case danish
    case finnish
    case polish
    case czech
    case filipino
    case persian
    case greek
    case romanian
    case hungarian
    case macedonian

    var title: String { rawValue.capitalized }
}

struct DictationPreferences {
    private enum Key {
        static let mode = "dictationMode"
        static let punctuation = "punctuationMode"
        static let qwenLanguage = "dictationLanguage"
        static let parakeetLanguage = "parakeetLanguage"
    }

    let mode: DictationMode
    let punctuation: PunctuationMode
    let language: DictationLanguage

    static var current: DictationPreferences {
        let defaults = UserDefaults.standard
        return DictationPreferences(
            mode: DictationMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .standard,
            punctuation: PunctuationMode(
                rawValue: defaults.string(forKey: Key.punctuation) ?? ""
            ) ?? .automatic,
            language: DictationLanguage(
                rawValue: defaults.string(forKey: Key.qwenLanguage) ?? ""
            ) ?? .auto
        )
    }

    static func language(for model: DictationModel) -> DictationLanguage {
        guard model.key != "qwen" else { return current.language }
        let stored = UserDefaults.standard.string(forKey: Key.parakeetLanguage) ?? ""
        let language = DictationLanguage(rawValue: stored) ?? .english
        return language == .auto ? .auto : .english
    }

    static func save(
        mode: DictationMode,
        punctuation: PunctuationMode,
        language: DictationLanguage,
        model: DictationModel
    ) {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(punctuation.rawValue, forKey: Key.punctuation)
        let key = model.key == "qwen" ? Key.qwenLanguage : Key.parakeetLanguage
        defaults.set(language.rawValue, forKey: key)
    }
}

struct UserSnippet: Codable, Hashable {
    var id: String
    var trigger: String
    var content: String
}

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

struct ManagedModel: Decodable, Hashable {
    let key: String
    let name: String
    let detail: String
    let downloadSizeBytes: Int64?
    let installedSizeBytes: Int64?
    let sizeText: String?
    let installed: Bool
    let downloading: Bool
    let deleting: Bool
    let loaded: Bool
    let downloadError: String?
    let progress: Double?
    let state: String?

    var sizeDescription: String {
        if let sizeText, !sizeText.isEmpty { return sizeText }
        if installed, let installedSizeBytes, installedSizeBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: installedSizeBytes, countStyle: .file)
        }
        if let downloadSizeBytes {
            return ByteCountFormatter.string(fromByteCount: downloadSizeBytes, countStyle: .file)
        }
        return DictationModel.all.first(where: { $0.key == key })?.detail.components(separatedBy: " · ").last
            ?? "Size unavailable"
    }

    var dictationModel: DictationModel? {
        DictationModel.all.first(where: { $0.key == key })
    }

    private enum CodingKeys: String, CodingKey {
        case key, name, label, detail, backend, size, sizeBytes = "size_bytes"
        case downloadSizeBytes = "download_size_bytes"
        case installedSizeBytes = "installed_size_bytes"
        case installed, downloaded, downloading, deleting, loaded, progress, state, status
        case downloadError = "download_error"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try values.decode(String.self, forKey: .key)
        key = decodedKey
        let known = DictationModel.all.first(where: { $0.key == decodedKey })
        let label = try values.decodeIfPresent(String.self, forKey: .label)
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? label?.replacingOccurrences(of: #"\s*\([^)]*(?:MB|GB)\)\s*$"#, with: "", options: .regularExpression)
            ?? known?.name
            ?? key
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
            ?? values.decodeIfPresent(String.self, forKey: .backend)
            ?? known?.detail.components(separatedBy: " · ").first
            ?? "Transcription model"
        downloadSizeBytes = try values.decodeIfPresent(Int64.self, forKey: .downloadSizeBytes)
            ?? values.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        installedSizeBytes = try values.decodeIfPresent(Int64.self, forKey: .installedSizeBytes)
        sizeText = try values.decodeIfPresent(String.self, forKey: .size)
            ?? label.flatMap(Self.sizeSuffix)
        installed = try values.decodeIfPresent(Bool.self, forKey: .installed)
            ?? values.decodeIfPresent(Bool.self, forKey: .downloaded)
            ?? false
        downloading = try values.decodeIfPresent(Bool.self, forKey: .downloading) ?? false
        deleting = try values.decodeIfPresent(Bool.self, forKey: .deleting) ?? false
        loaded = try values.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        downloadError = try values.decodeIfPresent(String.self, forKey: .downloadError)
        progress = try values.decodeIfPresent(Double.self, forKey: .progress)
        state = try values.decodeIfPresent(String.self, forKey: .state)
            ?? values.decodeIfPresent(String.self, forKey: .status)
    }

    init(key: String, payload: ModelPayload) {
        self.key = key
        let known = DictationModel.all.first(where: { $0.key == key })
        name = payload.name ?? payload.label.map {
            $0.replacingOccurrences(of: #"\s*\([^)]*(?:MB|GB)\)\s*$"#, with: "", options: .regularExpression)
        } ?? known?.name ?? key
        detail = payload.detail ?? payload.backend
            ?? known?.detail.components(separatedBy: " · ").first
            ?? "Transcription model"
        downloadSizeBytes = payload.download_size_bytes ?? payload.size_bytes
        installedSizeBytes = payload.installed_size_bytes
        sizeText = payload.size ?? payload.label.flatMap(Self.sizeSuffix)
        installed = payload.installed ?? payload.downloaded ?? false
        downloading = payload.downloading ?? false
        deleting = payload.deleting ?? false
        loaded = payload.loaded ?? false
        downloadError = payload.download_error
        progress = payload.progress
        state = payload.state ?? payload.status
    }

    private static func sizeSuffix(_ label: String) -> String? {
        guard let range = label.range(of: #"[0-9]+(?:\.[0-9]+)?\s*(?:MB|GB)"#, options: .regularExpression) else {
            return nil
        }
        return String(label[range])
    }
}

struct ModelPayload: Decodable {
    let name: String?
    let label: String?
    let detail: String?
    let backend: String?
    let size: String?
    let size_bytes: Int64?
    let download_size_bytes: Int64?
    let installed_size_bytes: Int64?
    let installed: Bool?
    let downloaded: Bool?
    let downloading: Bool?
    let deleting: Bool?
    let loaded: Bool?
    let download_error: String?
    let progress: Double?
    let state: String?
    let status: String?
}

struct ModelComparisonResult: Decodable {
    let modelKey: String
    let modelName: String?
    let text: String
    let transcriptionSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case modelKey = "model_key"
        case key
        case model
        case modelName = "model_name"
        case name
        case text
        case transcript
        case transcriptionSeconds = "transcription_seconds"
        case seconds
        case elapsedSeconds = "elapsed_seconds"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelKey = try values.decodeIfPresent(String.self, forKey: .modelKey)
            ?? values.decodeIfPresent(String.self, forKey: .key)
            ?? values.decodeIfPresent(String.self, forKey: .model)
            ?? ""
        modelName = try values.decodeIfPresent(String.self, forKey: .modelName)
            ?? values.decodeIfPresent(String.self, forKey: .name)
        text = try values.decodeIfPresent(String.self, forKey: .text)
            ?? values.decodeIfPresent(String.self, forKey: .transcript)
            ?? ""
        transcriptionSeconds = try values.decodeIfPresent(Double.self, forKey: .transcriptionSeconds)
            ?? values.decodeIfPresent(Double.self, forKey: .seconds)
            ?? values.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
            ?? 0
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFilePermissions.write(
            encoder.encode(VocabularyDocument(entries: entries)),
            to: url
        )
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

struct PrivacySettings: Codable, Equatable {
    let store_history: Bool
    let store_recordings: Bool
    let retention_days: Int
}

struct TranscriptionResponse: Decodable {
    let timestamp: String
    let model: String
    let audio_file: String?
    let transcription_seconds: Double
    let text: String
    let origin_bundle_id: String?
    let origin_app_name: String?
}

struct ErrorResponse: Decodable {
    let error: String
}
