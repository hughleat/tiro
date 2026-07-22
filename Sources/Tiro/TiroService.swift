import Foundation
import TiroRecognition

extension Notification.Name {
    static let tiroModelUseDidChange = Notification.Name("TiroModelUseDidChange")
}

@MainActor
final class TiroService {
    private static let speakerDiarizationKey = "coreml-speaker-diarization"
    private static let speakerDiarizationDownloadBytes: Int64 = 1_000_000_000
    private let store: NativeTiroStore?
    private let storeError: Error?
    private let appleSpeechEngine = AppleSpeechEngine()
    private let parakeetEngines: [String: CoreMLParakeetEngine]
    private let whisperEngines: [String: CoreMLWhisperEngine]
    private let speakerDiarizationEngine: SpeakerDiarizationEngine
    private let availableModelCapacity: () -> Int64?
    private let transcriptionGate = TranscriptionJobGate()
    private var activeModelUses = 0
    private var exclusiveModelUse = false
    private var recordingModelUse = false
    private var comparisonTasks: [String: Task<[ModelComparisonResult], Error>] = [:]
    private var mutatingModelKey: String?
    private var modelOperation: (key: String, operation: ManagedModelOperation)?
    private var modelOperationTask: Task<Void, Never>?
    private var modelOperationErrors: [String: String] = [:]
    private var modelCleanupErrors: [String: String] = [:]
    private var pendingCleanupKeys: Set<String> = []
    private var cleanupInProgress = false
    private var cleanupRetryAfter: Date?
    private var cleanupRetryTask: Task<Void, Never>?
    private var automaticCleanupRetryUsed = false

    var modelOperationInProgress: Bool {
        mutatingModelKey != nil || cleanupInProgress
    }

    var modelUseInProgress: Bool { activeModelUses > 0 || exclusiveModelUse }

    func beginRecordingModelUse() throws {
        guard !modelOperationInProgress, !modelUseInProgress else {
            throw TiroError.message("Wait for the current model operation to finish.")
        }
        recordingModelUse = true
        activeModelUses = 1
        postModelUseChange()
    }

    func endRecordingModelUse() {
        guard recordingModelUse else { return }
        recordingModelUse = false
        endModelUse()
    }

    init(
        availableModelCapacity: @escaping () -> Int64? = {
            ModelStorageCapacity.available(at: AppPaths.coreMLModelsDirectory)
        }
    ) {
        do {
            store = try NativeTiroStore(rootURL: AppPaths.dataDirectory)
            storeError = nil
        } catch {
            store = nil
            storeError = error
        }

        let root = AppPaths.coreMLModelsDirectory
        speakerDiarizationEngine = SpeakerDiarizationEngine(
            runtime: FluidAudioOnDemandDiarizationRuntime(modelsRootDirectory: root)
        )
        self.availableModelCapacity = availableModelCapacity
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
        pendingCleanupKeys = Set(parakeetEngines.keys)
            .union(whisperEngines.keys)
            .union([Self.speakerDiarizationKey])
    }

    func transcribe(
        audioURL: URL,
        model: DictationModel,
        originBundleID: String? = nil,
        originName: String? = nil,
        sourceFilename: String? = nil,
        archiveAudio: Bool = true,
        identifySpeakers: Bool = false,
        saveToHistory: Bool = true,
        usingRecordingReservation: Bool = false
    ) async throws -> TranscriptionResponse {
        try beginModelUse(allowingRecordingReservation: usingRecordingReservation)
        defer { endModelUse() }
        try await transcriptionGate.acquire()
        do {
            let response = try await performTranscription(
                audioURL: audioURL,
                model: model,
                originBundleID: originBundleID,
                originName: originName,
                sourceFilename: sourceFilename,
                archiveAudio: archiveAudio,
                identifySpeakers: identifySpeakers,
                saveToHistory: saveToHistory
            )
            await transcriptionGate.release()
            return response
        } catch {
            await transcriptionGate.release()
            throw error
        }
    }

    private func performTranscription(
        audioURL: URL,
        model: DictationModel,
        originBundleID: String?,
        originName: String?,
        sourceFilename: String?,
        archiveAudio: Bool,
        identifySpeakers: Bool,
        saveToHistory: Bool
    ) async throws -> TranscriptionResponse {
        try Task.checkCancellation()
        let preferences = DictationPreferences.snapshot(for: model)
        if identifySpeakers {
            let status = try await speakerDiarizationEngine.status()
            guard status.installed else {
                throw TiroError.message(
                    "Install Speaker Identification in Settings > Models before using it."
                )
            }
        }
        try await unloadModels(except: model.key)
        let contextualStrings = model.key == DictationModel.appleSpeechKey
            ? try await contextualStrings(for: originBundleID)
            : []
        let raw = try await rawTranscript(
            audioURL: audioURL,
            model: model,
            preferences: preferences,
            contextualStrings: contextualStrings
        )
        try Task.checkCancellation()
        try Self.requireDetectedSpeech(in: raw.text)
        let finalizationOptions = NativeTranscriptionOptions(
            mode: NativeDictationMode(rawValue: preferences.mode.rawValue) ?? .standard,
            punctuation: NativePunctuationMode(rawValue: preferences.punctuation.rawValue)
                ?? .automatic,
            language: preferences.language.title
        )
        let segments: [TranscriptSegment]
        let rawText: String
        if identifySpeakers {
            guard !raw.segments.isEmpty else {
                throw TiroError.message(
                    "The selected model did not provide the timestamps needed to identify speakers."
                )
            }
            let attributed: [TranscriptSegment]
            do {
                attributed = try await speakerDiarizationEngine.diarize(
                    audioURL,
                    transcriptSegments: raw.segments
                )
                try await speakerDiarizationEngine.unload()
            } catch {
                try? await speakerDiarizationEngine.unload()
                throw error
            }
            segments = try await finalizedSegments(
                attributed,
                options: finalizationOptions,
                originBundleID: originBundleID
            )
            rawText = Self.speakerAttributedText(segments)
        } else if raw.segments.isEmpty {
            segments = []
            rawText = raw.text
        } else {
            segments = try await finalizedSegments(
                raw.segments,
                options: finalizationOptions,
                originBundleID: originBundleID
            )
            rawText = segments.map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        try Task.checkCancellation()
        let store = try requireStore()
        let privacy = try await store.privacySettings()
        let shouldLoadAudio = archiveAudio
            && saveToHistory
            && privacy.storeHistory
            && privacy.storeRecordings
        let audio = shouldLoadAudio ? try Data(contentsOf: audioURL) : nil
        try Task.checkCancellation()
        let entry = try await requireStore().finalize(NativeFinalizationRequest(
            rawText: rawText,
            recognizedText: raw.text,
            modelID: model.key,
            transcriptionSeconds: raw.transcriptionSeconds,
            audio: audio,
            originBundleID: originBundleID,
            originAppName: originName,
            sourceFilename: sourceFilename,
            saveToHistory: saveToHistory,
            textIsFinalized: !segments.isEmpty,
            segments: segments,
            options: finalizationOptions
        ))
        return TranscriptionResponse(
            id: entry.id,
            timestamp: entry.timestamp,
            model: entry.model,
            audio_file: entry.audioFile,
            transcription_seconds: entry.transcriptionSeconds,
            text: entry.text,
            origin_bundle_id: entry.originBundleID,
            origin_app_name: entry.originAppName,
            source_filename: entry.sourceFilename,
            segments: segments
        )
    }

    func preload(
        model: DictationModel,
        usingRecordingReservation: Bool = false
    ) async throws {
        if usingRecordingReservation {
            try beginModelUse(allowingRecordingReservation: true)
        } else {
            try beginExclusiveModelUse()
        }
        defer {
            if usingRecordingReservation {
                endModelUse()
            } else {
                endExclusiveModelUse()
            }
        }
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
        try beginExclusiveModelUse()
        defer { endExclusiveModelUse() }
        try await unloadModels(except: model.key)
    }

    func select(model: DictationModel) throws {
        guard !modelUseInProgress, mutatingModelKey != model.key else {
            throw TiroError.message(
                "Wait for recording, transcription, or the \(model.name) operation to finish."
            )
        }
        DictationModel.select(model)
    }

    func models() async -> [ManagedModel] {
        await cleanupAbandonedDownloadsIfNeeded()
        let availableBytes = availableModelCapacity()
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
                    operation: nil,
                    loaded: availability.usable,
                    operationError: nil,
                    downloadSpace: nil,
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
            let activeOperation: ManagedModelOperation?
            if modelOperation?.key == model.key {
                switch modelOperation?.operation {
                case .downloading:
                    activeOperation = .downloading(
                        progress: status.downloadProgress
                    )
                case .cancelling:
                    activeOperation = .cancelling
                case .deleting:
                    activeOperation = .deleting
                case nil:
                    activeOperation = nil
                }
            } else {
                switch status.activity {
                case .downloading:
                    activeOperation = .downloading(
                        progress: status.downloadProgress
                    )
                case .deleting:
                    activeOperation = .deleting
                default:
                    activeOperation = nil
                }
            }
            let downloadSpace = model.downloadSizeBytes.map {
                ModelDownloadSpace(
                    downloadBytes: $0,
                    availableBytes: availableBytes
                )
            }
            result.append(ManagedModel(
                key: model.key,
                installedSizeBytes: status.installed ? status.sizeBytes : nil,
                installed: status.installed,
                usable: status.installed,
                operation: activeOperation,
                loaded: status.loaded,
                operationError: modelOperationErrors[model.key]
                    ?? modelCleanupErrors[model.key],
                downloadSpace: downloadSpace,
                state: Self.state(for: status)
            ))
        }
        if let status = try? await speakerDiarizationEngine.status() {
            let operation: ManagedModelOperation?
            if modelOperation?.key == Self.speakerDiarizationKey {
                switch modelOperation?.operation {
                case .downloading:
                    operation = .downloading(progress: status.downloadProgress)
                case .cancelling:
                    operation = .cancelling
                case .deleting:
                    operation = .deleting
                case nil:
                    operation = nil
                }
            } else {
                operation = nil
            }
            result.append(ManagedModel(
                key: Self.speakerDiarizationKey,
                name: "Speaker Identification",
                detail: "Labels speakers in imported audio and CLI transcripts",
                provisioning: .downloadable(bytes: Self.speakerDiarizationDownloadBytes),
                installedSizeBytes: status.installed ? status.sizeBytes : nil,
                installed: status.installed,
                operation: operation,
                loaded: status.loaded,
                operationError: modelOperationErrors[Self.speakerDiarizationKey]
                    ?? modelCleanupErrors[Self.speakerDiarizationKey]
                    ?? status.lastError,
                downloadSpace: ModelDownloadSpace(
                    downloadBytes: Self.speakerDiarizationDownloadBytes,
                    availableBytes: availableBytes
                ),
                state: Self.state(for: status)
            ))
        }
        return result
    }

    @discardableResult
    func startDownload(key: String) -> Bool {
        do {
            let downloadBytes: Int64
            if key == Self.speakerDiarizationKey {
                downloadBytes = Self.speakerDiarizationDownloadBytes
            } else {
                downloadBytes = try downloadableModel(key: key).downloadSizeBytes ?? 0
            }
            let space = ModelDownloadSpace(
                downloadBytes: downloadBytes,
                availableBytes: availableModelCapacity()
            )
            guard space.hasEnoughSpace else {
                modelOperationErrors[key] = nil
                return false
            }
            try beginModelMutation(key: key)
            modelOperationErrors[key] = nil
            modelOperation = (key, .downloading(progress: nil))
            modelOperationTask = Task { [weak self] in
                await self?.runDownload(key: key)
            }
            return true
        } catch {
            modelOperationErrors[key] = error.localizedDescription
            return false
        }
    }

    func startDelete(key: String) {
        do {
            guard DictationModel.selected.key != key else {
                throw TiroError.message(
                    "Select another transcription model before deleting this one."
                )
            }
            try beginModelMutation(key: key)
            modelOperationErrors[key] = nil
            modelOperation = (key, .deleting)
            modelOperationTask = Task { [weak self] in
                await self?.runDelete(key: key)
            }
        } catch {
            modelOperationErrors[key] = error.localizedDescription
        }
    }

    func cancelModelOperation(key: String) {
        guard modelOperation?.key == key,
              modelOperation?.operation.isDownloading == true else { return }
        modelOperation = (key, .cancelling)
        modelOperationTask?.cancel()
    }

    func modelOperationError(for key: String) -> String? {
        modelOperationErrors[key]
    }

    private func runDownload(key: String) async {
        do {
            if let engine = parakeetEngines[key] {
                try await engine.download()
            } else if let engine = whisperEngines[key] {
                try await engine.download()
            } else if key == Self.speakerDiarizationKey {
                try await speakerDiarizationEngine.download()
            } else {
                throw TiroError.message(
                    "The requested transcription model is unavailable."
                )
            }
            modelOperationErrors[key] = nil
            modelCleanupErrors[key] = nil
            pendingCleanupKeys.remove(key)
        } catch is CancellationError {
            modelOperationErrors[key] = nil
            scheduleCleanup(for: key)
        } catch {
            modelOperationErrors[key] = error.localizedDescription
            scheduleCleanup(for: key)
        }
        finishModelMutation(key: key)
    }

    private func runDelete(key: String) async {
        do {
            if let engine = parakeetEngines[key] {
                try await engine.delete()
            } else if let engine = whisperEngines[key] {
                try await engine.delete()
            } else if key == Self.speakerDiarizationKey {
                try await speakerDiarizationEngine.delete()
            } else {
                throw TiroError.message(
                    "The requested transcription model is unavailable."
                )
            }
            modelOperationErrors[key] = nil
            modelCleanupErrors[key] = nil
            pendingCleanupKeys.remove(key)
        } catch {
            modelOperationErrors[key] = error.localizedDescription
            scheduleCleanup(for: key)
        }
        finishModelMutation(key: key)
    }

    private func downloadableModel(key: String) throws -> DictationModel {
        guard key != DictationModel.appleSpeechKey,
              let model = DictationModel.all.first(where: { $0.key == key }),
              model.downloadSizeBytes != nil else {
            throw TiroError.message(
                "The requested transcription model is unavailable."
            )
        }
        return model
    }

    private func beginModelMutation(key: String) throws {
        guard mutatingModelKey == nil,
              !cleanupInProgress,
              !modelUseInProgress else {
            throw TiroError.message(
                "Wait for the current model operation to finish."
            )
        }
        mutatingModelKey = key
    }

    private func beginModelUse(allowingRecordingReservation: Bool = false) throws {
        let mayUseRecordingReservation = allowingRecordingReservation && recordingModelUse
        guard !modelOperationInProgress,
              !exclusiveModelUse,
              !recordingModelUse || mayUseRecordingReservation else {
            throw TiroError.message("Wait for the current model operation to finish.")
        }
        activeModelUses += 1
        postModelUseChange()
    }

    private func endModelUse() {
        activeModelUses = max(0, activeModelUses - 1)
        postModelUseChange()
        schedulePendingCleanupIfIdle()
    }

    private func beginExclusiveModelUse() throws {
        guard !modelOperationInProgress, !modelUseInProgress else {
            throw TiroError.message("Wait for the current model operation to finish.")
        }
        exclusiveModelUse = true
        postModelUseChange()
    }

    private func endExclusiveModelUse() {
        exclusiveModelUse = false
        postModelUseChange()
        schedulePendingCleanupIfIdle()
    }

    private func postModelUseChange() {
        NotificationCenter.default.post(name: .tiroModelUseDidChange, object: nil)
    }

    private func schedulePendingCleanupIfIdle() {
        guard !modelUseInProgress, !pendingCleanupKeys.isEmpty else { return }
        cleanupRetryAfter = nil
        automaticCleanupRetryUsed = false
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil
        scheduleAutomaticCleanupRetry(delay: 0)
    }

    private func finishModelMutation(key: String) {
        if mutatingModelKey == key {
            mutatingModelKey = nil
            modelOperation = nil
            modelOperationTask = nil
        }
    }

    private func cleanupAbandonedDownloadsIfNeeded() async {
        guard !cleanupInProgress,
              !pendingCleanupKeys.isEmpty,
              cleanupRetryAfter.map({ $0 <= Date() }) ?? true else { return }
        guard mutatingModelKey == nil, !modelUseInProgress else {
            cleanupRetryAfter = Date().addingTimeInterval(5)
            scheduleAutomaticCleanupRetry(delay: 5)
            return
        }
        cleanupInProgress = true
        defer { cleanupInProgress = false }

        for key in Array(pendingCleanupKeys) {
            do {
                if let engine = parakeetEngines[key] {
                    try await engine.cleanupAbandonedDownload()
                } else if let engine = whisperEngines[key] {
                    try await engine.cleanupAbandonedDownload()
                } else if key == Self.speakerDiarizationKey {
                    try await speakerDiarizationEngine.cleanupAbandonedDownload()
                }
                modelCleanupErrors[key] = nil
                pendingCleanupKeys.remove(key)
            } catch {
                modelCleanupErrors[key] =
                    "Could not clean up an interrupted download: \(error.localizedDescription)"
            }
        }
        cleanupRetryAfter = pendingCleanupKeys.isEmpty
            ? nil
            : Date().addingTimeInterval(30)
        if pendingCleanupKeys.isEmpty {
            cleanupRetryTask?.cancel()
            cleanupRetryTask = nil
        } else {
            scheduleAutomaticCleanupRetry()
        }
    }

    private func scheduleCleanup(for key: String) {
        pendingCleanupKeys.insert(key)
        cleanupRetryAfter = nil
        automaticCleanupRetryUsed = false
    }

    private func scheduleAutomaticCleanupRetry(delay: TimeInterval = 30) {
        guard !automaticCleanupRetryUsed, cleanupRetryTask == nil else { return }
        automaticCleanupRetryUsed = true
        cleanupRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            cleanupRetryTask = nil
            cleanupRetryAfter = nil
            await cleanupAbandonedDownloadsIfNeeded()
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
        try beginModelUse()
        defer { endModelUse() }
        let store = try requireStore()
        let audio = try await store.audio(forHistoryID: historyID)
        let temporaryURL = AppPaths.transientRecordingsDirectory
            .appendingPathComponent("comparison-\(comparisonID).wav")
        try PrivateFilePermissions.write(audio, to: temporaryURL)
        do {
            try await transcriptionGate.acquire()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

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
                        audioURL: temporaryURL,
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
            await transcriptionGate.release()
            return results
        } catch {
            comparisonTasks[comparisonID] = nil
            await transcriptionGate.release()
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
        audioURL: URL,
        model: DictationModel,
        preferences: DictationPreferences,
        contextualStrings: [String]
    ) async throws -> RawTranscript {
        if model.key == DictationModel.appleSpeechKey {
            let result = try await appleSpeechEngine.transcribe(
                audioURL,
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
                    : 0,
                segments: []
            )
        }
        if let engine = parakeetEngines[model.key] {
            try await engine.preload()
            return try await engine.transcribe(audioURL)
        }
        if let engine = whisperEngines[model.key] {
            try await engine.preload()
            let result = try await engine.transcribe(
                audioURL,
                options: WhisperDecodingOptions(language: preferences.language.whisperCode)
            )
            return RawTranscript(
                text: result.text,
                model: engine.model.recognitionModel,
                audioSeconds: result.audioSeconds,
                transcriptionSeconds: result.transcriptionSeconds,
                timesFasterThanRealtime: result.timesFasterThanRealtime,
                segments: result.segments
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
            sourceFilename: entry.sourceFilename,
            audioAvailable: entry.audioAvailable ?? false,
            audioFile: entry.audioFile,
            segments: entry.segments ?? []
        )
    }

    private static func state(for status: CoreMLModelStatus) -> String {
        if status.activity != .idle { return status.activity.rawValue }
        if status.loaded { return "ready" }
        return status.installed ? "installed" : "not_installed"
    }

    private static func speakerAttributedText(_ segments: [TranscriptSegment]) -> String {
        let speakerIDs = Array(Set(segments.compactMap(\.speakerID))).sorted()
        let labels = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)")
        })
        return segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let speakerID = segment.speakerID, let label = labels[speakerID] else {
                return text
            }
            return "\(label): \(text)"
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    nonisolated static func requireDetectedSpeech(in text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TiroError.noSpeechDetected
        }
    }

    private func finalizedSegments(
        _ segments: [TranscriptSegment],
        options: NativeTranscriptionOptions,
        originBundleID: String?
    ) async throws -> [TranscriptSegment] {
        let store = try requireStore()
        try Task.checkCancellation()
        let texts = try await store.finalizedTexts(
            segments.map(\.text),
            options: options,
            originBundleID: originBundleID
        )
        try Task.checkCancellation()
        return zip(segments, texts).map { segment, text in
            TranscriptSegment(
                text: text,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                speakerID: segment.speakerID,
                words: []
            )
        }
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
    case noSpeechDetected
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noSpeechDetected: "No speech was detected."
        case .message(let message): message
        }
    }
}
