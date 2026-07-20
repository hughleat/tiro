import CryptoKit
import Foundation
import TiroRecognition

actor NativeTiroStore {
    private enum Limits {
        static let history = 200
        static let vocabulary = 500
        static let profiles = 200
        static let snippets = 200
        static let snippetContent = 2_000
        static let transcript = 100_000
        static let transcriptSegments = 10_000
        static let transcriptWords = 100_000
        static let mediaSeconds = 86_400.0
        static let transcriptionSeconds = 3_600.0
    }

    let rootURL: URL
    private let files: NativeFiles
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        files = NativeFiles(root: rootURL.standardizedFileURL)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        try Self.preparePrivateDirectory(rootURL.standardizedFileURL, fileManager: fileManager)
        try Self.preparePrivateDirectory(files.audio, fileManager: fileManager)
        try Self.repairKnownFiles(files: files, fileManager: fileManager)
    }

    func finalize(_ request: NativeFinalizationRequest) throws -> NativeHistoryEntry {
        try Task.checkCancellation()
        let raw = request.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= Limits.transcript else {
            throw NativeStoreError.invalidData("Transcription text is too long.")
        }
        guard request.transcriptionSeconds.isFinite,
              (0...Limits.transcriptionSeconds).contains(request.transcriptionSeconds) else {
            throw NativeStoreError.invalidData("Transcription duration is invalid.")
        }
        let originBundleID = try bounded(request.originBundleID, maximum: 255, label: "Bundle ID")
        let originAppName = try bounded(request.originAppName, maximum: 200, label: "App name")
        let sourceFilename = try bounded(
            request.sourceFilename,
            maximum: 255,
            label: "Source filename"
        )
        let segments = try validatedSegments(request.segments)
        let text = request.textIsFinalized
            ? raw
            : try finalizedTexts(
                [raw],
                options: request.options,
                originBundleID: originBundleID
            )[0]
        let recognizedText = try bounded(
            request.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            maximum: Limits.transcript,
            label: "Recognized transcription"
        )
        let privacy = try privacySettings()
        var entry = NativeHistoryEntry(
            id: request.id.uuidString.lowercased(),
            timestamp: Self.timestampFormatter.string(from: request.timestamp),
            model: request.modelID,
            transcriptionSeconds: (request.transcriptionSeconds * 1_000).rounded() / 1_000,
            text: text,
            mode: request.options.mode,
            punctuation: request.options.punctuation,
            language: request.options.language,
            rawText: recognizedText.flatMap { $0 == text ? nil : $0 }
                ?? (text == raw ? nil : raw),
            correctedText: nil,
            originBundleID: originBundleID,
            originAppName: originAppName,
            sourceFilename: sourceFilename,
            audioFile: nil,
            audioAvailable: nil,
            segments: segments.isEmpty ? nil : segments
        )
        guard privacy.storeHistory, request.saveToHistory else { return entry }

        var recordedURL: URL?
        do {
            try Task.checkCancellation()
            if privacy.storeRecordings, let audio = request.audio {
                let name = Self.audioTimestampFormatter.string(from: request.timestamp) +
                    "-\(request.id.uuidString.lowercased()).wav"
                let url = files.audio.appendingPathComponent(name)
                try writePrivate(audio, to: url)
                recordedURL = url
                entry.audioFile = relativeAudioPath(name: name)
            }
            try Task.checkCancellation()
            var entries = try loadHistory()
            entries.append(entry)
            try saveHistory(entries)
        } catch {
            if let recordedURL {
                try? fileManager.removeItem(at: recordedURL)
            }
            throw error
        }
        _ = try applyRetention(now: request.timestamp)
        return entry
    }

    func finalizedTexts(
        _ rawTexts: [String],
        options: NativeTranscriptionOptions,
        originBundleID: String?
    ) throws -> [String] {
        let bundleID = try bounded(originBundleID, maximum: 255, label: "Bundle ID")
        let vocabulary = try loadVocabulary()
        let profiles = try loadProfiles().profiles
        let snippets = try loadSnippets()
        return try rawTexts.map { rawText in
            let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count <= Limits.transcript else {
                throw NativeStoreError.invalidData("Transcription text is too long.")
            }
            return NativeTextFinalizer.finalize(
                raw,
                options: options,
                vocabulary: vocabulary,
                profiles: profiles,
                snippets: snippets,
                originBundleID: bundleID
            )
        }
    }

    private func validatedSegments(
        _ segments: [TranscriptSegment]
    ) throws -> [TranscriptSegment] {
        guard segments.count <= Limits.transcriptSegments else {
            throw NativeStoreError.invalidData("The transcription contains too many segments.")
        }
        var wordCount = 0
        var textCount = 0
        for segment in segments {
            textCount += segment.text.count
            wordCount += segment.words.count
            guard textCount <= Limits.transcript,
                  wordCount <= Limits.transcriptWords,
                  segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds >= segment.startSeconds,
                  segment.endSeconds <= Limits.mediaSeconds,
                  (segment.speakerID?.count ?? 0) <= 128 else {
                throw NativeStoreError.invalidData("The transcription timing data is invalid.")
            }
            for word in segment.words {
                guard word.text.count <= 1_000,
                      word.startSeconds.isFinite,
                      word.endSeconds.isFinite,
                      word.startSeconds >= segment.startSeconds,
                      word.endSeconds >= word.startSeconds,
                      word.endSeconds <= segment.endSeconds else {
                    throw NativeStoreError.invalidData("The transcription word data is invalid.")
                }
            }
        }
        return segments
    }

    func privacySettings() throws -> NativePrivacySettings {
        if !fileManager.fileExists(atPath: files.privacy.path) {
            let legacy = fileManager.fileExists(atPath: files.history.path) ||
                fileManager.fileExists(atPath: files.retention.path)
            let settings: NativePrivacySettings
            if legacy {
                settings = NativePrivacySettings(
                    storeHistory: true,
                    storeRecordings: true,
                    retentionDays: legacyRetentionDays()
                )
            } else {
                settings = .newInstall
            }
            try saveDocument(settings, to: files.privacy)
            return settings
        }
        return try loadDocument(NativePrivacySettings.self, from: files.privacy).validated()
    }

    @discardableResult
    func updatePrivacySettings(
        _ settings: NativePrivacySettings,
        now: Date = Date()
    ) throws -> Int {
        let settings = try settings.validated()
        let oldData = try? Data(contentsOf: files.privacy)
        try saveDocument(settings, to: files.privacy)
        do {
            return try applyRetention(days: settings.retentionDays, now: now)
        } catch {
            if let oldData {
                try? writePrivate(oldData, to: files.privacy)
            } else {
                try? fileManager.removeItem(at: files.privacy)
            }
            throw error
        }
    }

    func searchHistory(query: String = "", limit: Int = 20) throws -> [NativeHistoryEntry] {
        let query = NativeTextFinalizer.folded(query)
        let limit = max(0, min(limit, Limits.history))
        guard limit > 0 else { return [] }
        return try loadHistory().reversed().filter { entry in
            query.isEmpty || [
                entry.text,
                entry.rawText,
                entry.correctedText,
                entry.model,
                entry.originAppName,
            ]
            .compactMap { $0 }
            .contains { NativeTextFinalizer.folded($0).contains(query) }
        }
        .prefix(limit)
        .map { entry in
            var entry = entry
            entry.audioAvailable = entry.audioFile.flatMap { try? audioURL(for: $0) }
                .map { fileManager.fileExists(atPath: $0.path) } ?? false
            return entry
        }
    }

    func audio(forHistoryID id: String) throws -> Data {
        guard let entry = try loadHistory().first(where: { $0.id == id }),
              let path = entry.audioFile else {
            throw NativeStoreError.missingHistoryEntry
        }
        return try Data(contentsOf: audioURL(for: path))
    }

    @discardableResult
    func deleteHistoryEntry(id: String) throws -> Bool {
        var entries = try loadHistory()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let removed = entries.remove(at: index)
        let audioURL = try unreferencedAudioURL(removed.audioFile, kept: entries)
        try saveHistory(entries)
        if let audioURL { try? fileManager.removeItem(at: audioURL) }
        return true
    }

    func deleteAllHistory() throws {
        try saveHistory([])
        if fileManager.fileExists(atPath: files.audio.path) {
            for url in try fileManager.contentsOfDirectory(
                at: files.audio,
                includingPropertiesForKeys: nil
            ) {
                try fileManager.removeItem(at: url)
            }
        }
        try saveDocument(NativeSuggestionsDocument(), to: files.suggestions)
    }

    @discardableResult
    func applyRetention(days: Int? = nil, now: Date = Date()) throws -> Int {
        let days = try days ?? privacySettings().retentionDays
        guard NativePrivacySettings.allowedRetentionDays.contains(days) else {
            throw NativeStoreError.invalidData("Retention must be 0, 1, 7, 30, or 90 days.")
        }
        guard days != 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let entries = try loadHistory()
        let kept = entries.filter {
            guard let timestamp = Self.parseTimestamp($0.timestamp) else { return false }
            return timestamp >= cutoff
        }
        let removed = entries.filter { entry in !kept.contains(where: { $0.id == entry.id }) }
        guard !removed.isEmpty else { return 0 }
        let audioURLs = try removed.compactMap {
            try unreferencedAudioURL($0.audioFile, kept: kept)
        }
        try saveHistory(kept)
        for audioURL in audioURLs { try? fileManager.removeItem(at: audioURL) }
        return removed.count
    }

    func vocabulary() throws -> [NativeVocabularyEntry] {
        try loadVocabulary()
    }

    func saveVocabulary(_ entries: [NativeVocabularyEntry]) throws {
        guard entries.count <= Limits.vocabulary else {
            throw NativeStoreError.invalidData("Vocabulary supports at most 500 entries.")
        }
        try saveDocument(
            NativeVocabularyDocument(entries: try entries.map { try $0.validated() }),
            to: files.vocabulary
        )
    }

    func vocabularyProfiles() throws -> NativeVocabularyProfilesDocument {
        try loadProfiles()
    }

    func saveVocabularyProfiles(_ document: NativeVocabularyProfilesDocument) throws {
        guard document.version == 1, document.profiles.count <= Limits.profiles else {
            throw NativeStoreError.invalidData("Vocabulary profiles document is invalid.")
        }
        var profiles: [NativeVocabularyProfile] = []
        for profile in document.profiles {
            let bundleID = try bounded(profile.bundleID, maximum: 255, label: "Bundle ID")
            let name = try bounded(profile.name, maximum: 200, label: "App name") ?? ""
            guard let bundleID else {
                throw NativeStoreError.invalidData("Profile bundle IDs cannot be empty.")
            }
            guard profile.entries.count <= Limits.vocabulary else {
                throw NativeStoreError.invalidData("A profile supports at most 500 entries.")
            }
            profiles.append(NativeVocabularyProfile(
                bundleID: bundleID,
                name: name,
                entries: try profile.entries.map { try $0.validated() }
            ))
        }
        try saveDocument(
            NativeVocabularyProfilesDocument(profiles: profiles),
            to: files.profiles
        )
    }

    func snippets() throws -> [NativeSnippet] {
        try loadSnippets()
    }

    @discardableResult
    func saveSnippet(_ input: NativeSnippet) throws -> NativeSnippet {
        let snippet = try validatedSnippet(input)
        var snippets = try loadSnippets()
        let replacing = snippets.contains { $0.id == snippet.id }
        guard replacing || snippets.count < Limits.snippets else {
            throw NativeStoreError.invalidData("Snippets support at most 200 items.")
        }
        snippets.removeAll { $0.id == snippet.id }
        snippets.append(snippet)
        try validateUniqueSnippets(snippets)
        try saveDocument(NativeSnippetsDocument(snippets: snippets), to: files.snippets)
        return snippet
    }

    @discardableResult
    func deleteSnippet(id: String) throws -> Bool {
        var snippets = try loadSnippets()
        let count = snippets.count
        snippets.removeAll { $0.id == id }
        guard snippets.count != count else { return false }
        try saveDocument(NativeSnippetsDocument(snippets: snippets), to: files.snippets)
        return true
    }

    @discardableResult
    func correctHistoryEntry(id: String, correctedText: String) throws -> Bool {
        guard correctedText.count <= Limits.transcript else {
            throw NativeStoreError.invalidData("Corrected transcription text is too long.")
        }
        var entries = try loadHistory()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].correctedText = correctedText
        entries[index].segments = nil
        try saveHistory(entries)
        return true
    }

    func suggestions() throws -> [NativeVocabularySuggestion] {
        let document = try reconcileSuggestions(history: loadHistory())
        return document.suggestions.filter {
            $0.count >= 2 && !$0.accepted && !$0.dismissed && !suggestionIsCovered($0)
        }
    }

    @discardableResult
    func dismissSuggestion(id: String) throws -> Bool {
        var document = try loadSuggestions()
        guard let index = document.suggestions.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard !document.suggestions[index].accepted else {
            throw NativeStoreError.invalidData("An accepted suggestion cannot be dismissed.")
        }
        document.suggestions[index].dismissed = true
        try saveDocument(document, to: files.suggestions)
        return true
    }

    func acceptSuggestion(id: String, scope: NativeSuggestionScope) throws -> NativeSuggestionScope {
        var document = try loadSuggestions()
        guard let index = document.suggestions.firstIndex(where: { $0.id == id }) else {
            throw NativeStoreError.missingSuggestion
        }
        var suggestion = document.suggestions[index]
        guard !suggestion.dismissed else {
            throw NativeStoreError.invalidData("A dismissed suggestion cannot be accepted.")
        }
        if let acceptedScope = suggestion.acceptedScope { return acceptedScope }
        guard suggestion.count >= 2 else { throw NativeStoreError.missingSuggestion }

        switch scope {
        case .global:
            var entries = try loadVocabulary()
            replaceRule(in: &entries, spoken: suggestion.spoken, written: suggestion.written)
            try saveVocabulary(entries)
        case .profile:
            guard !suggestion.originBundleID.isEmpty else {
                throw NativeStoreError.invalidData("Profile suggestions require an app bundle ID.")
            }
            var profiles = try loadProfiles()
            let index = profiles.profiles.lastIndex {
                $0.bundleID == suggestion.originBundleID
            }
            if let index {
                replaceRule(
                    in: &profiles.profiles[index].entries,
                    spoken: suggestion.spoken,
                    written: suggestion.written
                )
            } else {
                guard profiles.profiles.count < Limits.profiles else {
                    throw NativeStoreError.invalidData("Vocabulary supports at most 200 profiles.")
                }
                profiles.profiles.append(NativeVocabularyProfile(
                    bundleID: suggestion.originBundleID,
                    name: suggestion.originAppName,
                    entries: [NativeVocabularyEntry(
                        spoken: suggestion.spoken,
                        written: suggestion.written
                    )]
                ))
            }
            try saveVocabularyProfiles(profiles)
        }
        suggestion.accepted = true
        suggestion.dismissed = false
        suggestion.acceptedScope = scope
        suggestion.acceptingScope = nil
        document.suggestions[index] = suggestion
        try saveDocument(document, to: files.suggestions)
        return scope
    }

    private func loadVocabulary() throws -> [NativeVocabularyEntry] {
        guard fileManager.fileExists(atPath: files.vocabulary.path) else { return [] }
        let document = try loadDocument(NativeVocabularyDocument.self, from: files.vocabulary)
        return try document.entries.prefix(Limits.vocabulary).map { try $0.validated() }
    }

    private func loadProfiles() throws -> NativeVocabularyProfilesDocument {
        guard fileManager.fileExists(atPath: files.profiles.path) else {
            return NativeVocabularyProfilesDocument()
        }
        let document = try loadDocument(
            NativeVocabularyProfilesDocument.self,
            from: files.profiles
        )
        guard document.version == 1 else {
            throw NativeStoreError.invalidData("Vocabulary profiles version must be 1.")
        }
        return document
    }

    private func loadSnippets() throws -> [NativeSnippet] {
        guard fileManager.fileExists(atPath: files.snippets.path) else { return [] }
        let document = try loadDocument(NativeSnippetsDocument.self, from: files.snippets)
        guard document.version == 1 else {
            throw NativeStoreError.invalidData("Snippets version must be 1.")
        }
        let snippets = try document.snippets.map(validatedSnippet)
        try validateUniqueSnippets(snippets)
        return snippets
    }

    private func loadHistory() throws -> [NativeHistoryEntry] {
        guard fileManager.fileExists(atPath: files.history.path) else { return [] }
        let text = try String(contentsOf: files.history, encoding: .utf8)
        do {
            return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
                try decoder.decode(NativeHistoryEntry.self, from: Data($0.utf8))
            }
        } catch {
            throw NativeStoreError.invalidData(
                "history.jsonl contains an unreadable entry; no history was changed."
            )
        }
    }

    private func saveHistory(_ entries: [NativeHistoryEntry]) throws {
        let data = try entries.reduce(into: Data()) { result, entry in
            result.append(try encoder.encode(entry))
            result.append(0x0A)
        }
        try writePrivate(data, to: files.history)
    }

    private func loadSuggestions() throws -> NativeSuggestionsDocument {
        guard fileManager.fileExists(atPath: files.suggestions.path) else {
            return NativeSuggestionsDocument()
        }
        let document = try loadDocument(
            NativeSuggestionsDocument.self,
            from: files.suggestions
        )
        guard document.version == 1 else {
            throw NativeStoreError.invalidData("Suggestions version must be 1.")
        }
        return document
    }

    @discardableResult
    private func reconcileSuggestions(
        history: [NativeHistoryEntry]
    ) throws -> NativeSuggestionsDocument {
        let document = try reconciledSuggestions(history: history)
        try saveDocument(document, to: files.suggestions)
        return document
    }

    private func reconciledSuggestions(
        history: [NativeHistoryEntry]
    ) throws -> NativeSuggestionsDocument {
        let previous = try loadSuggestions()
        let decisions = Dictionary(
            uniqueKeysWithValues: previous.suggestions
                .filter { $0.accepted || $0.dismissed || $0.acceptingScope != nil }
                .map { ($0.id, $0) }
        )
        var evidence: [String: NativeVocabularySuggestion] = [:]
        for entry in history {
            guard let corrected = entry.correctedText,
                  let candidate = suggestionCandidate(entry: entry, correctedText: corrected) else {
                continue
            }
            let id = suggestionID(candidate)
            if evidence[id] == nil {
                evidence[id] = NativeVocabularySuggestion(
                    id: id,
                    spoken: candidate.spoken,
                    written: candidate.written,
                    originBundleID: candidate.bundleID,
                    originAppName: candidate.appName,
                    transcriptionIDs: [],
                    count: 0,
                    accepted: false,
                    dismissed: false,
                    acceptedScope: nil,
                    acceptingScope: nil
                )
            }
            if !evidence[id]!.transcriptionIDs.contains(entry.id),
               evidence[id]!.transcriptionIDs.count < 1_000 {
                evidence[id]!.transcriptionIDs.append(entry.id)
                evidence[id]!.count = evidence[id]!.transcriptionIDs.count
            }
        }
        var suggestions = evidence.values.map { suggestion in
            guard let decision = decisions[suggestion.id] else { return suggestion }
            var suggestion = suggestion
            suggestion.accepted = decision.accepted
            suggestion.dismissed = decision.dismissed
            suggestion.acceptedScope = decision.acceptedScope
            suggestion.acceptingScope = decision.acceptingScope
            return suggestion
        }
        suggestions.sort { $0.id < $1.id }
        return NativeSuggestionsDocument(suggestions: suggestions)
    }

    private func suggestionCandidate(
        entry: NativeHistoryEntry,
        correctedText: String
    ) -> NativeSuggestionCandidate? {
        let before = NativeTextFinalizer.wordTokens(entry.text)
        let after = NativeTextFinalizer.wordTokens(correctedText)
        guard !before.isEmpty, !after.isEmpty else { return nil }
        let beforeFolded = before.map(NativeTextFinalizer.folded)
        let afterFolded = after.map(NativeTextFinalizer.folded)
        var prefix = 0
        while prefix < min(before.count, after.count),
              beforeFolded[prefix] == afterFolded[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(before.count - prefix, after.count - prefix),
              beforeFolded[before.count - suffix - 1] == afterFolded[after.count - suffix - 1] {
            suffix += 1
        }
        let oldWords = Array(before[prefix..<(before.count - suffix)])
        let newWords = Array(after[prefix..<(after.count - suffix)])
        guard (1...3).contains(oldWords.count), (1...3).contains(newWords.count) else { return nil }
        let changed = max(oldWords.count, newWords.count)
        guard changed == 1 || changed * 2 <= max(before.count, after.count) else { return nil }
        let foldedOld = oldWords.map(NativeTextFinalizer.folded)
        let occurrences = beforeFolded.indices.filter { start in
            start + foldedOld.count <= beforeFolded.count &&
                Array(beforeFolded[start..<(start + foldedOld.count)]) == foldedOld
        }.count
        guard occurrences == 1 else { return nil }

        var spoken = oldWords.joined(separator: " ")
        if let rawText = entry.rawText, rawText != entry.text {
            let raw = NativeTextFinalizer.wordTokens(rawText)
            let rawFolded = raw.map(NativeTextFinalizer.folded)
            if raw.count == before.count,
               rawFolded.enumerated().allSatisfy({ index, word in
                   (prefix..<(prefix + oldWords.count)).contains(index) ||
                       word == beforeFolded[index]
               }) {
                spoken = raw[prefix..<(prefix + oldWords.count)].joined(separator: " ")
            }
        }
        let written = newWords.joined(separator: " ")
        guard spoken.count <= 100, written.count <= 100 else { return nil }
        return NativeSuggestionCandidate(
            spoken: spoken,
            written: written,
            bundleID: boundedOrigin(entry.originBundleID, maximum: 255),
            appName: boundedOrigin(entry.originAppName, maximum: 200)
        )
    }

    private func suggestionID(_ candidate: NativeSuggestionCandidate) -> String {
        let framed = try! encoder.encode([
            NativeTextFinalizer.folded(candidate.spoken),
            NativeTextFinalizer.folded(candidate.written),
            candidate.bundleID,
        ])
        return Self.uuid5(
            namespace: UUID(uuidString: "ad2d6d17-a3ef-49df-bbd5-ed73ad9b81cb")!,
            name: framed
        ).uuidString.lowercased()
    }

    private func suggestionIsCovered(_ suggestion: NativeVocabularySuggestion) -> Bool {
        let entries = (try? loadVocabulary()) ?? []
        let profiles = (try? loadProfiles().profiles) ?? []
        return NativeTextFinalizer.vocabularyForOrigin(
            suggestion.originBundleID.isEmpty ? nil : suggestion.originBundleID,
            global: entries,
            profiles: profiles
        ).contains {
            NativeTextFinalizer.folded($0.spoken) == NativeTextFinalizer.folded(suggestion.spoken) &&
                NativeTextFinalizer.folded($0.written) == NativeTextFinalizer.folded(suggestion.written)
        }
    }

    private func replaceRule(
        in entries: inout [NativeVocabularyEntry],
        spoken: String,
        written: String
    ) {
        let key = NativeTextFinalizer.folded(spoken)
        entries.removeAll { NativeTextFinalizer.folded($0.spoken) == key }
        entries.append(NativeVocabularyEntry(spoken: spoken, written: written))
    }

    private func validatedSnippet(_ snippet: NativeSnippet) throws -> NativeSnippet {
        let id = snippet.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = snippet.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 200,
              !trigger.isEmpty, trigger.count <= 200,
              !content.isEmpty, content.count <= Limits.snippetContent else {
            throw NativeStoreError.invalidData("Snippet fields are invalid.")
        }
        return NativeSnippet(id: id, trigger: trigger, content: content)
    }

    private func validateUniqueSnippets(_ snippets: [NativeSnippet]) throws {
        guard Set(snippets.map(\.id)).count == snippets.count,
              Set(snippets.map { NativeTextFinalizer.folded($0.trigger) }).count == snippets.count else {
            throw NativeStoreError.invalidData("Snippet IDs and triggers must be unique.")
        }
    }

    private func legacyRetentionDays() -> Int {
        guard let document = try? loadDocument(
            NativeLegacyRetention.self,
            from: files.retention
        ), NativePrivacySettings.allowedRetentionDays.contains(document.days) else {
            return 0
        }
        return document.days
    }

    private func bounded(_ value: String?, maximum: Int, label: String) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximum else {
            throw NativeStoreError.invalidData("\(label) exceeds \(maximum) characters.")
        }
        return trimmed
    }

    private func boundedOrigin(_ value: String?, maximum: Int) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximum ? trimmed : ""
    }

    private func relativeAudioPath(name: String) -> String {
        "\(rootURL.lastPathComponent)/audio/\(name)"
    }

    private func audioURL(for storedPath: String) throws -> URL {
        let candidate: URL
        if storedPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: storedPath)
        } else if storedPath.hasPrefix("\(rootURL.lastPathComponent)/") {
            candidate = rootURL.deletingLastPathComponent().appendingPathComponent(storedPath)
        } else {
            candidate = rootURL.appendingPathComponent(storedPath)
        }
        let resolvedRoot = files.audio.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw NativeStoreError.unsafePath(candidate)
        }
        try Self.rejectSymbolicLink(resolved, fileManager: fileManager)
        return resolved
    }

    private func unreferencedAudioURL(
        _ path: String?,
        kept: [NativeHistoryEntry]
    ) throws -> URL? {
        guard let path, !kept.contains(where: { $0.audioFile == path }) else {
            return nil
        }
        return try audioURL(for: path)
    }

    private func loadDocument<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw NativeStoreError.invalidData("\(url.lastPathComponent) is malformed.")
        }
    }

    private func saveDocument<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        try writePrivate(data, to: url)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try Self.rejectSymbolicLink(url, fileManager: fileManager)
        try Self.preparePrivateDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try rejectSymbolicLink(url, fileManager: fileManager)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func rejectSymbolicLink(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw NativeStoreError.unsafePath(url)
        }
    }

    private static func repairKnownFiles(files: NativeFiles, fileManager: FileManager) throws {
        for url in files.mutableFiles where fileManager.fileExists(atPath: url.path) {
            try rejectSymbolicLink(url, fileManager: fileManager)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func uuid5(namespace: UUID, name: Data) -> UUID {
        var namespace = namespace.uuid
        let namespaceData = withUnsafeBytes(of: &namespace) { Data($0) }
        let digest = Insecure.SHA1.hash(data: namespaceData + name)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        timestampFormatter.date(from: value) ??
            ISO8601DateFormatter().date(from: value)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let audioTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSSSSS'Z'"
        return formatter
    }()
}

private struct NativeFiles {
    let root: URL
    var audio: URL { root.appendingPathComponent("audio", isDirectory: true) }
    var history: URL { root.appendingPathComponent("history.jsonl") }
    var retention: URL { root.appendingPathComponent("retention.json") }
    var privacy: URL { root.appendingPathComponent("privacy.json") }
    var vocabulary: URL { root.appendingPathComponent("vocabulary.json") }
    var profiles: URL { root.appendingPathComponent("profiles.json") }
    var suggestions: URL { root.appendingPathComponent("suggestions.json") }
    var snippets: URL { root.appendingPathComponent("snippets.json") }
    var mutableFiles: [URL] {
        [history, retention, privacy, vocabulary, profiles, suggestions, snippets]
    }
}

private struct NativeLegacyRetention: Codable {
    let days: Int
}

private struct NativeSuggestionCandidate {
    let spoken: String
    let written: String
    let bundleID: String
    let appName: String
}
