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
    static let initialText = "yarna = Janne\nyana = Janne\njana = Janne\n"

    static func load(from url: URL = AppPaths.vocabularyFile) throws -> String {
        if FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        try save(initialText, to: url)
        return initialText
    }

    static func save(_ text: String, to url: URL = AppPaths.vocabularyFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
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
