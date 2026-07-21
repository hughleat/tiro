import Foundation
import TiroRecognition

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

    var whisperCode: String? {
        switch self {
        case .auto: nil
        case .english: "en"
        case .cantonese: "yue"
        case .arabic: "ar"
        case .french: "fr"
        case .german: "de"
        case .spanish: "es"
        case .italian: "it"
        case .portuguese: "pt"
        case .dutch: "nl"
        case .chinese: "zh"
        case .japanese: "ja"
        case .korean: "ko"
        case .russian: "ru"
        case .indonesian: "id"
        case .thai: "th"
        case .vietnamese: "vi"
        case .turkish: "tr"
        case .hindi: "hi"
        case .malay: "ms"
        case .swedish: "sv"
        case .danish: "da"
        case .finnish: "fi"
        case .polish: "pl"
        case .czech: "cs"
        case .filipino: "tl"
        case .persian: "fa"
        case .greek: "el"
        case .romanian: "ro"
        case .hungarian: "hu"
        case .macedonian: "mk"
        }
    }

    var appleLocaleIdentifier: String {
        guard let code = whisperCode else { return Locale.current.identifier }
        if let preferred = Locale.preferredLanguages.first(where: {
            Locale(identifier: $0).language.languageCode?.identifier == code
        }) {
            return preferred
        }
        return Self.appleLocaleDefaults[code] ?? code
    }

    private static let appleLocaleDefaults = [
        "yue": "yue-HK", "en": "en-US", "ar": "ar-SA", "fr": "fr-FR",
        "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-PT",
        "nl": "nl-NL", "zh": "zh-CN", "ja": "ja-JP", "ko": "ko-KR",
        "ru": "ru-RU", "id": "id-ID", "th": "th-TH", "vi": "vi-VN",
        "tr": "tr-TR", "hi": "hi-IN", "ms": "ms-MY", "sv": "sv-SE",
        "da": "da-DK", "fi": "fi-FI", "pl": "pl-PL", "cs": "cs-CZ",
        "tl": "fil-PH", "fa": "fa-IR", "el": "el-GR", "ro": "ro-RO",
        "hu": "hu-HU", "mk": "mk-MK",
    ]
}

struct DictationPreferences {
    private enum Key {
        static let mode = "dictationMode"
        static let punctuation = "punctuationMode"
        static let language = "dictationLanguage"
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
                rawValue: defaults.string(forKey: Key.language) ?? ""
            ) ?? .auto
        )
    }

    static func snapshot(for model: DictationModel) -> DictationPreferences {
        let current = current
        return DictationPreferences(
            mode: current.mode,
            punctuation: current.punctuation,
            language: language(for: model)
        )
    }

    static func language(for model: DictationModel) -> DictationLanguage {
        switch model.languageSupport {
        case .english:
            return .english
        case .automatic:
            return .auto
        case .selectable:
            return current.language
        }
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
        if model.languageSupport == .selectable {
            defaults.set(language.rawValue, forKey: Key.language)
        }
    }
}

struct UserSnippet: Codable, Hashable {
    var id: String
    var trigger: String
    var content: String
}

struct DictationModel: Hashable {
    enum LanguageSupport: Hashable {
        case english
        case automatic
        case selectable
    }

    enum Provisioning: Hashable {
        case systemManaged
        case downloadable(bytes: Int64)
    }

    let key: String
    let name: String
    let detail: String
    let provisioning: Provisioning
    let languageSupport: LanguageSupport
    let isSupported: Bool

    var downloadSizeBytes: Int64? {
        guard case .downloadable(let bytes) = provisioning else { return nil }
        return bytes
    }

    static let appleSpeechKey = "apple-speech"
    static let coreMLCompactKey = "coreml-compact"
    static let appleSpeech = DictationModel(
        key: appleSpeechKey,
        name: "Apple Speech",
        detail: "Apple recognition · On-device",
        provisioning: .systemManaged,
        languageSupport: .selectable,
        isSupported: true
    )
    static let coreMLCompact = DictationModel(
        key: coreMLCompactKey,
        name: "Parakeet Compact",
        detail: "English · Fastest Parakeet",
        provisioning: .downloadable(bytes: 228_000_000),
        languageSupport: .english,
        isSupported: true
    )

    static let catalog: [DictationModel] = [
        appleSpeech,
        coreMLCompact,
        .init(
            key: "coreml-parakeet-v2",
            name: "Parakeet 0.6B v2",
            detail: "English · Recommended",
            provisioning: .downloadable(bytes: 500_000_000),
            languageSupport: .english,
            isSupported: true
        ),
        .init(
            key: "coreml-parakeet-v3",
            name: "Parakeet 0.6B v3",
            detail: "Multilingual · Automatic detection",
            provisioning: .downloadable(bytes: 520_000_000),
            languageSupport: .automatic,
            isSupported: true
        ),
        .init(
            key: "coreml-whisper-tiny-english",
            name: "Whisper Tiny English",
            detail: "English · Fastest Whisper",
            provisioning: .downloadable(bytes: 154_000_000),
            languageSupport: .english,
            isSupported: WhisperModel.tinyEnglish.isSupportedOnCurrentDevice
        ),
        .init(
            key: "coreml-whisper-base-english",
            name: "Whisper Base English",
            detail: "English · Lightweight",
            provisioning: .downloadable(bytes: 290_000_000),
            languageSupport: .english,
            isSupported: WhisperModel.baseEnglish.isSupportedOnCurrentDevice
        ),
        .init(
            key: "coreml-whisper-small-english",
            name: "Whisper Small English",
            detail: "English · Balanced",
            provisioning: .downloadable(bytes: 922_000_000),
            languageSupport: .english,
            isSupported: WhisperModel.smallEnglish.isSupportedOnCurrentDevice
        ),
        .init(
            key: "coreml-whisper-tiny",
            name: "Whisper Tiny",
            detail: "Multilingual · Fastest Whisper",
            provisioning: .downloadable(bytes: 154_000_000),
            languageSupport: .selectable,
            isSupported: true
        ),
        .init(
            key: "coreml-whisper-base",
            name: "Whisper Base",
            detail: "Multilingual · Lightweight",
            provisioning: .downloadable(bytes: 290_000_000),
            languageSupport: .selectable,
            isSupported: true
        ),
        .init(
            key: "coreml-whisper-small",
            name: "Whisper Small",
            detail: "Multilingual · Balanced",
            provisioning: .downloadable(bytes: 922_000_000),
            languageSupport: .selectable,
            isSupported: true
        ),
        .init(
            key: "coreml-whisper-distil-large-v3",
            name: "Distil Whisper Large V3",
            detail: "Multilingual · Fast high accuracy",
            provisioning: .downloadable(bytes: 594_000_000),
            languageSupport: .selectable,
            isSupported: WhisperModel.distilLargeV3.isSupportedOnCurrentDevice
        ),
        .init(
            key: "coreml-whisper-large-v3",
            name: "Whisper Large V3",
            detail: "Multilingual · High accuracy",
            provisioning: .downloadable(bytes: 626_000_000),
            languageSupport: .selectable,
            isSupported: true
        ),
        .init(
            key: "coreml-whisper-turbo",
            name: "Whisper Large V3 Turbo",
            detail: "Multilingual · Fast and accurate",
            provisioning: .downloadable(bytes: 632_000_000),
            languageSupport: .selectable,
            isSupported: WhisperModel.turbo.isSupportedOnCurrentDevice
        ),
    ]

    static let all = catalog.filter(\.isSupported)

    static var selected: DictationModel {
        let key = UserDefaults.standard.string(forKey: "selectedModel") ?? coreMLCompactKey
        return all.first(where: { $0.key == key }) ?? all[0]
    }

    static func select(_ model: DictationModel) {
        UserDefaults.standard.set(model.key, forKey: "selectedModel")
    }
}

struct ManagedModel: Hashable {
    let key: String
    let name: String
    let detail: String
    let provisioning: DictationModel.Provisioning
    let installedSizeBytes: Int64?
    let installed: Bool
    let usable: Bool
    let operation: ManagedModelOperation?
    let loaded: Bool
    let operationError: String?
    let downloadSpace: ModelDownloadSpace?
    let state: String?

    var isSystemManaged: Bool { provisioning == .systemManaged }
    var downloading: Bool { operation?.isDownloading == true }
    var deleting: Bool { operation?.isDeleting == true }

    var progress: Double? {
        guard case .downloading(let progress) = operation else { return nil }
        return progress
    }

    var downloadSizeBytes: Int64? {
        guard case .downloadable(let bytes) = provisioning else { return nil }
        return bytes
    }

    var sizeDescription: String {
        if isSystemManaged {
            return "Provided by macOS"
        }
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

    init(
        key: String,
        name: String? = nil,
        detail: String? = nil,
        provisioning: DictationModel.Provisioning? = nil,
        installedSizeBytes: Int64?,
        installed: Bool,
        usable: Bool? = nil,
        operation: ManagedModelOperation?,
        loaded: Bool,
        operationError: String?,
        downloadSpace: ModelDownloadSpace?,
        state: String?
    ) {
        self.key = key
        let known = DictationModel.all.first(where: { $0.key == key })
        self.name = name ?? known?.name ?? key
        self.detail = detail ?? known?.detail ?? "Transcription model"
        self.provisioning = provisioning ?? known?.provisioning ?? .downloadable(bytes: 0)
        self.installedSizeBytes = installedSizeBytes
        self.installed = installed
        self.usable = usable ?? installed
        self.operation = operation
        self.loaded = loaded
        self.operationError = operationError
        self.downloadSpace = downloadSpace
        self.state = state
    }

}

struct ModelComparisonResult {
    let modelKey: String
    let modelName: String?
    let text: String
    let transcriptionSeconds: Double
    let error: String?

    init(
        modelKey: String,
        modelName: String?,
        text: String,
        transcriptionSeconds: Double,
        error: String? = nil
    ) {
        self.modelKey = modelKey
        self.modelName = modelName
        self.text = text
        self.transcriptionSeconds = transcriptionSeconds
        self.error = error
    }

}

struct HistoryEntry {
    let id: String
    let timestamp: String
    let model: String
    let transcription_seconds: Double
    let text: String
    let raw_text: String?
    let corrected_text: String?
    let origin_bundle_id: String?
    let origin_app_name: String?
    let source_filename: String?
    let audio_available: Bool
    let segments: [TranscriptSegment]

    var displayText: String { corrected_text ?? text }

    let audio_file: String?

    init(
        id: String,
        timestamp: String,
        model: String,
        transcriptionSeconds: Double,
        text: String,
        rawText: String?,
        correctedText: String?,
        originBundleID: String?,
        originAppName: String?,
        sourceFilename: String?,
        audioAvailable: Bool,
        audioFile: String?,
        segments: [TranscriptSegment] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        transcription_seconds = transcriptionSeconds
        self.text = text
        raw_text = rawText
        corrected_text = correctedText
        origin_bundle_id = originBundleID
        origin_app_name = originAppName
        source_filename = sourceFilename
        audio_available = audioAvailable
        audio_file = audioFile
        self.segments = segments
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

struct VocabularyProfilesDocument: Equatable {
    var version: Int
    var profiles: [VocabularyProfile]

    init(version: Int = 1, profiles: [VocabularyProfile] = []) {
        self.version = version
        self.profiles = profiles
    }
}

struct VocabularyProfile: Equatable {
    var bundle_id: String
    var name: String
    var entries: [VocabularyEntry]

    var displayBundleID: String { bundle_id.removingPercentEncoding ?? bundle_id }
    var displayName: String { name.removingPercentEncoding ?? name }
}

struct VocabularySuggestion {
    let id: String
    let spoken: String
    let written: String
    let origin_bundle_id: String?
    let origin_app_name: String?
    let count: Int

    var displayBundleID: String? {
        origin_bundle_id.flatMap { $0.removingPercentEncoding ?? $0 }
    }

    init(
        id: String,
        spoken: String,
        written: String,
        originBundleID: String?,
        originAppName: String?,
        count: Int
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        origin_bundle_id = originBundleID
        origin_app_name = originAppName
        self.count = count
    }

}

struct PrivacySettings: Equatable {
    let store_history: Bool
    let store_recordings: Bool
    let retention_days: Int
}

struct TranscriptionResponse {
    let id: String
    let timestamp: String
    let model: String
    let audio_file: String?
    let transcription_seconds: Double
    let text: String
    let origin_bundle_id: String?
    let origin_app_name: String?
    let source_filename: String?
    let segments: [TranscriptSegment]
}
