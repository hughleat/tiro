import Foundation

enum NativeTextFinalizer {
    private static let formattingCommands = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
    ]
    private static let punctuationCommands = [
        ("exclamation mark", "!"),
        ("question mark", "?"),
        ("semicolon", ";"),
        ("full stop", "."),
        ("period", "."),
        ("colon", ":"),
        ("comma", ","),
    ]
    private static let wordExpression = try! NSRegularExpression(
        pattern: #"[^\W_]+(?:['’][^\W_]+)*"#,
        options: [.useUnicodeWordBoundaries]
    )

    static func finalize(
        _ rawText: String,
        options: NativeTranscriptionOptions,
        vocabulary: [NativeVocabularyEntry],
        profiles: [NativeVocabularyProfile],
        snippets: [NativeSnippet],
        originBundleID: String?
    ) -> String {
        guard options.mode == .standard else { return rawText }
        let formatted = applySpokenFormatting(rawText, punctuation: options.punctuation)
        let vocabulary = vocabularyForOrigin(
            originBundleID,
            global: vocabulary,
            profiles: profiles
        )
        let substituted = applyRules(formatted, rules: vocabulary)
        return applyRules(
            substituted,
            rules: snippets.map { NativeVocabularyEntry(spoken: $0.trigger, written: $0.content) }
        )
    }

    static func vocabularyForOrigin(
        _ bundleID: String?,
        global: [NativeVocabularyEntry],
        profiles: [NativeVocabularyProfile]
    ) -> [NativeVocabularyEntry] {
        guard let bundleID,
              let profile = profiles.last(where: { $0.bundleID == bundleID }) else {
            return global
        }
        let overridden = Set(profile.entries.map { folded($0.spoken) })
        return global.filter { !overridden.contains(folded($0.spoken)) } + profile.entries
    }

    static func applyRules(_ text: String, rules: [NativeVocabularyEntry]) -> String {
        var effective: [String: NativeVocabularyEntry] = [:]
        for rule in rules {
            effective[folded(rule.spoken)] = rule
        }
        let alternatives = effective.values
            .map(\.spoken)
            .sorted { $0.count > $1.count }
        guard !alternatives.isEmpty else { return text }

        let pattern = #"(?<!\w)(?:"# +
            alternatives.map(NSRegularExpression.escapedPattern).joined(separator: "|") +
            #")(?!\w)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ) else {
            return text
        }
        let result = NSMutableString(string: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            let matched = (text as NSString).substring(with: match.range)
            guard let replacement = effective[folded(matched)]?.written else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    static func applySpokenFormatting(
        _ source: String,
        punctuation: NativePunctuationMode
    ) -> String {
        var text = source
        var markers: [(String, String)] = []
        var commands = formattingCommands
        if punctuation == .spoken {
            commands += punctuationCommands
        }
        for (index, command) in commands.enumerated() {
            let marker = "\u{E000}\(index)\u{E001}"
            markers.append((marker, command.1))
            text = replaceCommand(command.0, with: marker, in: text)
        }
        if punctuation == .spoken || punctuation == .none {
            text = removingPunctuation(from: text)
        }
        for (marker, replacement) in markers {
            text = text.replacingOccurrences(of: marker, with: replacement)
        }
        text = replacing(#"[ \t]+([,.;:?!])"#, with: "$1", in: text)
        text = replacing(#"([,.;:?!])(?=\w)"#, with: "$1 ", in: text)
        text = replacing(#" *\n *"#, with: "\n", in: text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
    }

    static func wordTokens(_ text: String) -> [String] {
        wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func replaceCommand(_ command: String, with replacement: String, in text: String) -> String {
        replacing(
            #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: command) + #"(?!\w)"#,
            with: NSRegularExpression.escapedTemplate(for: replacement),
            in: text,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        )
    }

    private static func replacing(
        _ pattern: String,
        with replacement: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private static func removingPunctuation(from text: String) -> String {
        let characters = Array(text)
        let lexical = CharacterSet(charactersIn: "'’ʼ-‐‑")
        var result = ""
        for index in characters.indices {
            let character = characters[index]
            let scalars = character.unicodeScalars
            let punctuation = scalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0)
            }
            let lexicalPunctuation = scalars.allSatisfy { lexical.contains($0) }
            let insideWord = lexicalPunctuation &&
                index > characters.startIndex &&
                index < characters.index(before: characters.endIndex) &&
                characters[characters.index(before: index)].isLetterOrNumber &&
                characters[characters.index(after: index)].isLetterOrNumber
            result.append(contentsOf: punctuation && !insideWord ? " " : String(character))
        }
        result = replacing(#"[ \t]+"#, with: " ", in: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}
