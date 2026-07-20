import Foundation
import TiroRecognition

@MainActor
final class TiroService {
    private let store: NativeTiroStore?
    private let storeError: Error?
    private let appleSpeechEngine = AppleSpeechEngine()
    private let parakeetEngines: [String: CoreMLParakeetEngine]
    private let whisperEngines: [String: CoreMLWhisperEngine]
    private var comparisonTasks: [String: Task<[ModelComparisonResult], Error>] = [:]
    private var mutatingModelKey: String?

    init() {
        do {
            store = try NativeTiroStore(rootURL: AppPaths.dataDirectory)
            storeError = nil
        } catch {
            store = nil
            storeError = error
        }

        let root = AppPaths.coreMLModelsDirectory
        parakeetEngines = [
            DictationModel.coreMLCompactKey: CoreMLParakeetEngine(
                model: .compact,
                modelsRootDirectory: root
            ),
            "coreml-parakeet-v2": CoreMLParakeetEngine(
                model: .v2,
                modelsRootDirectory: root
            ),
            "coreml-parakeet-v3": CoreMLParakeetEngine(
                model: .v3,
                modelsRootDirectory: root
            ),
        ]
        whisperEngines = [
            "coreml-whisper-tiny-english": CoreMLWhisperEngine(
                model: .tinyEnglish,
                modelsRootDirectory: root
            ),
            "coreml-whisper-base-english": CoreMLWhisperEngine(
                model: .baseEnglish,
                modelsRootDirectory: root
            ),
            "coreml-whisper-small-english": CoreMLWhisperEngine(
                model: .smallEnglish,
                modelsRootDirectory: root
            ),
            "coreml-whisper-tiny": CoreMLWhisperEngine(model: .tiny, modelsRootDirectory: root),
            "coreml-whisper-base": CoreMLWhisperEngine(model: .base, modelsRootDirectory: root),
            "coreml-whisper-small": CoreMLWhisperEngine(model: .small, modelsRootDirectory: root),
            "coreml-whisper-distil-large-v3": CoreMLWhisperEngine(
                model: .distilLargeV3,
                modelsRootDirectory: root
            ),
            "coreml-whisper-large-v3": CoreMLWhisperEngine(model: .largeV3, modelsRootDirectory: root),
            "coreml-whisper-turbo": CoreMLWhisperEngine(model: .turbo, modelsRootDirectory: root),
        ]
    }

    func transcribe(
        wavURL: URL,
        model: DictationModel,
        originBundleID: String? = nil,
        originName: String? = nil
    ) async throws -> TranscriptionResponse {
        let preferences = DictationPreferences.snapshot(for: model)
        try await unloadModels(except: model.key)
        let contextualStrings = model.key == DictationModel.appleSpeechKey
            ? try await contextualStrings(for: originBundleID)
            : []
        let raw = try await rawTranscript(
            wavURL: wavURL,
            model: model,
            preferences: preferences,
            contextualStrings: contextualStrings
        )
        try Task.checkCancellation()
        let audio = try Data(contentsOf: wavURL)
        try Task.checkCancellation()
        let entry = try await requireStore().finalize(NativeFinalizationRequest(
            rawText: raw.text,
            modelID: model.key,
            transcriptionSeconds: raw.transcriptionSeconds,
            audio: audio,
            originBundleID: originBundleID,
            originAppName: originName,
            options: NativeTranscriptionOptions(
                mode: NativeDictationMode(rawValue: preferences.mode.rawValue) ?? .standard,
                punctuation: NativePunctuationMode(rawValue: preferences.punctuation.rawValue)
                    ?? .automatic,
                language: preferences.language.title
            )
        ))
        return TranscriptionResponse(
            timestamp: entry.timestamp,
            model: entry.model,
            audio_file: entry.audioFile,
            transcription_seconds: entry.transcriptionSeconds,
            text: entry.text,
            origin_bundle_id: entry.originBundleID,
            origin_app_name: entry.originAppName
        )
    }

    func preload(model: DictationModel) async throws {
        try await unloadModels(except: model.key)
        if model.key == DictationModel.appleSpeechKey {
            let locale = DictationPreferences.language(for: model).appleLocaleIdentifier
            let availability = AppleSpeechEngine.availability(localeIdentifier: locale)
            guard availability.permissionGranted else {
                throw AppleSpeechError.permissionDenied
            }
            guard availability.usable else {
                throw AppleSpeechError.onDeviceRecognitionUnavailable(locale)
            }
            return
        } else if let engine = parakeetEngines[model.key] {
            try await engine.preload()
        } else if let engine = whisperEngines[model.key] {
            try await engine.preload()
        } else {
            throw TiroError.message("The selected transcription model is unavailable.")
        }
    }

    func activate(model: DictationModel) async throws {
        guard DictationModel.selected.key == model.key else { return }
        try await unloadModels(except: model.key)
    }

    func select(model: DictationModel) throws {
        guard mutatingModelKey != model.key else {
            throw TiroError.message(
                "Wait for the \(model.name) operation to finish before selecting it."
            )
        }
        DictationModel.select(model)
    }

    func models() async -> [ManagedModel] {
        var result: [ManagedModel] = []
        for model in DictationModel.all {
            if model.key == DictationModel.appleSpeechKey {
                let availability = AppleSpeechEngine.availability(
                    localeIdentifier: DictationPreferences.language(for: model)
                        .appleLocaleIdentifier
                )
                result.append(ManagedModel(
                    key: model.key,
                    installedSizeBytes: nil,
                    installed: availability.permissionGranted,
                    usable: availability.usable,
                    downloading: false,
                    deleting: false,
                    loaded: availability.usable,
                    downloadError: nil,
                    progress: nil,
                    state: availability.state.rawValue
                ))
                continue
            }
            let status: CoreMLModelStatus?
            if let engine = parakeetEngines[model.key] {
                status = await engine.status()
            } else if let engine = whisperEngines[model.key] {
                status = await engine.status()
            } else {
                status = nil
            }
            guard let status else { continue }
            result.append(ManagedModel(
                key: model.key,
                installedSizeBytes: status.installed ? status.sizeBytes : nil,
                installed: status.installed,
                usable: status.installed,
                downloading: status.activity == .downloading,
                deleting: status.activity == .deleting,
                loaded: status.loaded,
                downloadError: status.lastError,
                progress: status.downloadProgress,
                state: Self.state(for: status)
            ))
        }
        return result
    }

    func downloadModel(key: String) async throws {
        try beginModelMutation(key: key)
        defer { finishModelMutation(key: key) }
        if key == DictationModel.appleSpeechKey {
            throw TiroError.message("Apple Speech is managed by macOS and needs no Tiro download.")
        } else if let engine = parakeetEngines[key] {
            try await engine.download()
        } else if let engine = whisperEngines[key] {
            try await engine.download()
        } else {
            throw TiroError.message("The requested transcription model is unavailable.")
        }
    }

    func deleteModel(key: String) async throws {
        guard DictationModel.selected.key != key else {
            throw TiroError.message(
                "Select another transcription model before deleting this one."
            )
        }
        try beginModelMutation(key: key)
        defer { finishModelMutation(key: key) }
        if key == DictationModel.appleSpeechKey {
            throw TiroError.message("Apple Speech is managed by macOS and cannot be deleted by Tiro.")
        } else if let engine = parakeetEngines[key] {
            try await engine.delete()
        } else if let engine = whisperEngines[key] {
            try await engine.delete()
        } else {
            throw TiroError.message("The requested transcription model is unavailable.")
        }
    }

    private func beginModelMutation(key: String) throws {
        guard mutatingModelKey == nil else {
            throw TiroError.message(
                "Wait for the current model operation to finish."
            )
        }
        mutatingModelKey = key
    }

    private func finishModelMutation(key: String) {
        if mutatingModelKey == key {
            mutatingModelKey = nil
        }
    }

    func snippets() async throws -> [UserSnippet] {
        try await requireStore().snippets().map {
            UserSnippet(id: $0.id, trigger: $0.trigger, content: $0.content)
        }
    }

    func saveSnippet(_ snippet: UserSnippet) async throws -> UserSnippet {
        let saved = try await requireStore().saveSnippet(NativeSnippet(
            id: snippet.id,
            trigger: snippet.trigger,
            content: snippet.content
        ))
        return UserSnippet(id: saved.id, trigger: saved.trigger, content: saved.content)
    }

    func deleteSnippet(id: String) async throws {
        _ = try await requireStore().deleteSnippet(id: id)
    }

    func compareModels(
        historyID: String,
        modelKeys: [String],
        comparisonID: String
    ) async throws -> [ModelComparisonResult] {
        let store = try requireStore()
        let audio = try await store.audio(forHistoryID: historyID)
        let temporaryURL = AppPaths.transientRecordingsDirectory
            .appendingPathComponent("comparison-\(comparisonID).wav")
        try PrivateFilePermissions.write(audio, to: temporaryURL)

        let task = Task<[ModelComparisonResult], Error> { @MainActor [weak self] in
            guard let self else { return [ModelComparisonResult]() }
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            var results: [ModelComparisonResult] = []
            for key in modelKeys {
                try Task.checkCancellation()
                guard let model = DictationModel.all.first(where: { $0.key == key }) else {
                    continue
                }
                try await unloadModels(except: key)
                let current = DictationPreferences.snapshot(for: model)
                let language = model.key == DictationModel.appleSpeechKey
                    ? current.language
                    : .auto
                do {
                    let raw = try await rawTranscript(
                        wavURL: temporaryURL,
                        model: model,
                        preferences: DictationPreferences(
                            mode: current.mode,
                            punctuation: current.punctuation,
                            language: language
                        ),
                        contextualStrings: []
                    )
                    results.append(ModelComparisonResult(
                        modelKey: key,
                        modelName: model.name,
                        text: raw.text,
                        transcriptionSeconds: raw.transcriptionSeconds
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(ModelComparisonResult(
                        modelKey: key,
                        modelName: model.name,
                        text: "",
                        transcriptionSeconds: 0,
                        error: error.localizedDescription
                    ))
                }
            }
            return results
        }
        comparisonTasks[comparisonID] = task
        do {
            let results = try await task.value
            comparisonTasks[comparisonID] = nil
            return results
        } catch {
            comparisonTasks[comparisonID] = nil
            throw error
        }
    }

    func cancelComparison(id: String) {
        comparisonTasks.removeValue(forKey: id)?.cancel()
    }

    func searchHistory(query: String = "", limit: Int = 200) async throws -> [HistoryEntry] {
        try await requireStore().searchHistory(query: query, limit: limit).map(Self.historyEntry)
    }

    func historyAudio(id: String) async throws -> Data {
        try await requireStore().audio(forHistoryID: id)
    }

    func deleteHistoryEntry(id: String) async throws {
        _ = try await requireStore().deleteHistoryEntry(id: id)
    }

    func correctHistoryEntry(id: String, correctedText: String) async throws {
        _ = try await requireStore().correctHistoryEntry(id: id, correctedText: correctedText)
    }

    func privacySettings() async throws -> PrivacySettings {
        let settings = try await requireStore().privacySettings()
        return PrivacySettings(
            store_history: settings.storeHistory,
            store_recordings: settings.storeRecordings,
            retention_days: settings.retentionDays
        )
    }

    func updatePrivacySettings(_ settings: PrivacySettings) async throws -> PrivacySettings {
        try Self.validatePrivacySettings(settings)
        let native = NativePrivacySettings(
            storeHistory: settings.store_history,
            storeRecordings: settings.store_recordings,
            retentionDays: settings.retention_days
        )
        _ = try await requireStore().updatePrivacySettings(native)
        return settings
    }

    func deleteAllHistory() async throws {
        try await requireStore().deleteAllHistory()
    }

    nonisolated static func validatePrivacySettings(_ settings: PrivacySettings) throws {
        guard !settings.store_recordings || settings.store_history else {
            throw TiroError.message(
                "Recordings can only be kept when transcription history is saved."
            )
        }
        guard NativePrivacySettings.allowedRetentionDays.contains(settings.retention_days) else {
            throw TiroError.message("Retention must be Forever, 1, 7, 30, or 90 days.")
        }
    }

    func vocabularyProfiles() async throws -> VocabularyProfilesDocument {
        let document = try await requireStore().vocabularyProfiles()
        return VocabularyProfilesDocument(
            version: document.version,
            profiles: document.profiles.map {
                VocabularyProfile(
                    bundle_id: $0.bundleID,
                    name: $0.name,
                    entries: $0.entries.map {
                        VocabularyEntry(spoken: $0.spoken, written: $0.written)
                    }
                )
            }
        )
    }

    func saveGlobalVocabulary(
        _ editedEntries: [VocabularyEntry],
        replacing baselineEntries: [VocabularyEntry]
    ) async throws -> [VocabularyEntry] {
        let latestEntries = try await requireStore().vocabulary().map {
            VocabularyEntry(spoken: $0.spoken, written: $0.written)
        }
        let mergedEntries = Self.mergeVocabulary(
            latest: latestEntries,
            edited: editedEntries,
            baseline: baselineEntries
        )
        try await requireStore().saveVocabulary(mergedEntries.map {
            NativeVocabularyEntry(spoken: $0.spoken, written: $0.written)
        })
        return mergedEntries
    }

    func saveVocabularyProfile(
        _ editedProfile: VocabularyProfile,
        replacing baselineProfile: VocabularyProfile
    ) async throws -> VocabularyProfilesDocument {
        var document = try await vocabularyProfiles()
        let profileIndex = document.profiles.firstIndex {
            $0.bundle_id == editedProfile.bundle_id
        }
        var latestProfile = profileIndex.map { document.profiles[$0] }
            ?? VocabularyProfile(
                bundle_id: editedProfile.bundle_id,
                name: editedProfile.name,
                entries: []
            )
        latestProfile.entries = Self.mergeVocabulary(
            latest: latestProfile.entries,
            edited: editedProfile.entries,
            baseline: baselineProfile.entries
        )
        latestProfile.name = editedProfile.name
        if let profileIndex {
            document.profiles[profileIndex] = latestProfile
        } else {
            document.profiles.append(latestProfile)
        }
        try await requireStore().saveVocabularyProfiles(NativeVocabularyProfilesDocument(
            version: document.version,
            profiles: document.profiles.map {
                NativeVocabularyProfile(
                    bundleID: $0.bundle_id,
                    name: $0.name,
                    entries: $0.entries.map {
                        NativeVocabularyEntry(spoken: $0.spoken, written: $0.written)
                    }
                )
            }
        ))
        return document
    }

    func suggestions() async throws -> [VocabularySuggestion] {
        try await requireStore().suggestions().map {
            VocabularySuggestion(
                id: $0.id,
                spoken: $0.spoken,
                written: $0.written,
                originBundleID: $0.originBundleID.isEmpty ? nil : $0.originBundleID,
                originAppName: $0.originAppName.isEmpty ? nil : $0.originAppName,
                count: $0.count
            )
        }
    }

    func acceptSuggestion(id: String, scope: SuggestionScope) async throws {
        _ = try await requireStore().acceptSuggestion(
            id: id,
            scope: NativeSuggestionScope(rawValue: scope.rawValue) ?? .global
        )
    }

    func dismissSuggestion(id: String) async throws {
        _ = try await requireStore().dismissSuggestion(id: id)
    }

    private func rawTranscript(
        wavURL: URL,
        model: DictationModel,
        preferences: DictationPreferences,
        contextualStrings: [String]
    ) async throws -> RawTranscript {
        if model.key == DictationModel.appleSpeechKey {
            let result = try await appleSpeechEngine.transcribe(
                wavURL,
                options: AppleSpeechOptions(
                    localeIdentifier: preferences.language.appleLocaleIdentifier,
                    contextualStrings: contextualStrings
                )
            )
            return RawTranscript(
                text: result.text,
                model: .appleSpeech,
                audioSeconds: result.audioSeconds,
                transcriptionSeconds: result.transcriptionSeconds,
                timesFasterThanRealtime: result.transcriptionSeconds > 0
                    ? result.audioSeconds / result.transcriptionSeconds
                    : 0
            )
        }
        if let engine = parakeetEngines[model.key] {
            try await engine.preload()
            return try await engine.transcribe(wavURL)
        }
        if let engine = whisperEngines[model.key] {
            try await engine.preload()
            let result = try await engine.transcribe(
                wavURL,
                options: WhisperDecodingOptions(language: preferences.language.whisperCode)
            )
            return RawTranscript(
                text: result.text,
                model: engine.model.recognitionModel,
                audioSeconds: result.audioSeconds,
                transcriptionSeconds: result.transcriptionSeconds,
                timesFasterThanRealtime: result.timesFasterThanRealtime
            )
        }
        throw TiroError.message("The selected transcription model is unavailable.")
    }

    private func contextualStrings(for bundleID: String?) async throws -> [String] {
        let store = try requireStore()
        var terms: [String] = []
        if let bundleID {
            let profiles = try await store.vocabularyProfiles()
            terms = profiles.profiles
                .first(where: { $0.bundleID == bundleID })?
                .entries
                .map(\.written) ?? []
        }
        terms += try await store.vocabulary().map(\.written)
        var seen = Set<String>()
        return terms.filter {
            let key = $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !$0.isEmpty && seen.insert(key).inserted
        }
        .prefix(100)
        .map { $0 }
    }

    private func unloadModels(except retainedKey: String?) async throws {
        for (key, engine) in parakeetEngines where key != retainedKey {
            if (await engine.status()).loaded {
                try await engine.unload()
            }
        }
        for (key, engine) in whisperEngines where key != retainedKey {
            if (await engine.status()).loaded {
                try await engine.unload()
            }
        }
    }

    private func requireStore() throws -> NativeTiroStore {
        if let store { return store }
        throw storeError ?? TiroError.message("Tiro could not open its local data store.")
    }

    private static func historyEntry(_ entry: NativeHistoryEntry) -> HistoryEntry {
        HistoryEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            model: entry.model,
            transcriptionSeconds: entry.transcriptionSeconds,
            text: entry.text,
            rawText: entry.rawText,
            correctedText: entry.correctedText,
            originBundleID: entry.originBundleID,
            originAppName: entry.originAppName,
            audioAvailable: entry.audioAvailable ?? false,
            audioFile: entry.audioFile
        )
    }

    private static func state(for status: CoreMLModelStatus) -> String {
        if status.activity != .idle { return status.activity.rawValue }
        if status.loaded { return "ready" }
        return status.installed ? "installed" : "not_installed"
    }

    private static func mergeVocabulary(
        latest: [VocabularyEntry],
        edited: [VocabularyEntry],
        baseline: [VocabularyEntry]
    ) -> [VocabularyEntry] {
        let baselineByKey = Dictionary(
            baseline.map { (VocabularyEntry.normalized($0.spoken), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let editedByKey = Dictionary(
            edited.map { (VocabularyEntry.normalized($0.spoken), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let removedKeys = Set(baselineByKey.keys).subtracting(editedByKey.keys)
        var result = latest.filter {
            !removedKeys.contains(VocabularyEntry.normalized($0.spoken))
        }
        for (key, entry) in editedByKey where baselineByKey[key] != entry {
            if let index = result.firstIndex(where: {
                VocabularyEntry.normalized($0.spoken) == key
            }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result
    }
}

enum SuggestionScope: String {
    case profile
    case global
}

enum TiroError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
