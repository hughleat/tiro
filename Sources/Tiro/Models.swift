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
    let timestamp: String
    let model: String
    let audio_file: String
    let transcription_seconds: Double
    let text: String
    let raw_text: String?
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

struct VocabularyEntry: Codable {
    var spoken: String
    var written: String

    static func normalized(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil)
    }
}

struct TranscriptionResponse: Decodable {
    let timestamp: String
    let model: String
    let audio_file: String
    let transcription_seconds: Double
    let text: String
}

struct ErrorResponse: Decodable {
    let error: String
}
