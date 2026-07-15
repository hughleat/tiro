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
