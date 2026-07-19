import Foundation
import Testing
@testable import Tiro

@Suite
struct NativeTextFinalizerTests {
    @Test
    func standardPipelineAppliesFormattingBeforeReplacements() {
        let result = NativeTextFinalizer.finalize(
            "yana signature new line thanks period",
            options: NativeTranscriptionOptions(mode: .standard, punctuation: .spoken),
            vocabulary: [NativeVocabularyEntry(spoken: "yana", written: "Janne")],
            profiles: [],
            snippets: [NativeSnippet(
                id: "signature",
                trigger: "signature",
                content: "Best regards"
            )],
            originBundleID: nil
        )

        #expect(result == "Janne Best regards\nthanks.")
    }

    @Test
    func verbatimBypassesEveryTransformation() {
        let raw = "yana signature new line thanks period"
        let result = NativeTextFinalizer.finalize(
            raw,
            options: NativeTranscriptionOptions(mode: .verbatim, punctuation: .none),
            vocabulary: [NativeVocabularyEntry(spoken: "yana", written: "Janne")],
            profiles: [],
            snippets: [NativeSnippet(id: "signature", trigger: "signature", content: "Regards")],
            originBundleID: nil
        )

        #expect(result == raw)
    }

    @Test
    func profileRulesOverrideGlobalRulesAndLastProfileWins() {
        let profiles = [
            NativeVocabularyProfile(
                bundleID: "com.example.editor",
                name: "Old",
                entries: [NativeVocabularyEntry(spoken: "yana", written: "Jane")]
            ),
            NativeVocabularyProfile(
                bundleID: "com.example.editor",
                name: "Editor",
                entries: [NativeVocabularyEntry(spoken: "Yana", written: "Janne")]
            ),
        ]

        let result = NativeTextFinalizer.finalize(
            "Yana met Tiro",
            options: NativeTranscriptionOptions(),
            vocabulary: [
                NativeVocabularyEntry(spoken: "yana", written: "Global"),
                NativeVocabularyEntry(spoken: "Tiro", written: "TIRO"),
            ],
            profiles: profiles,
            snippets: [],
            originBundleID: "com.example.editor"
        )

        #expect(result == "Janne met TIRO")
    }

    @Test
    func substitutionsAreWholeWordLongestFirstAndDoNotChain() {
        let result = NativeTextFinalizer.applyRules(
            "new york met yana and yanas",
            rules: [
                NativeVocabularyEntry(spoken: "new", written: "old"),
                NativeVocabularyEntry(spoken: "new york", written: "New York"),
                NativeVocabularyEntry(spoken: "yana", written: "Janne"),
                NativeVocabularyEntry(spoken: "Janne", written: "Someone else"),
            ]
        )

        #expect(result == "New York met Janne and yanas")
    }

    @Test
    func punctuationModesApplySpokenAndVerbatimRules() {
        #expect(NativeTextFinalizer.applySpokenFormatting(
            "Hello, comma world period new paragraph next question mark",
            punctuation: .spoken
        ) == "Hello, world.\n\nnext?")
        #expect(NativeTextFinalizer.applySpokenFormatting(
            "don't stop l’amour state-of-the-art!",
            punctuation: .none
        ) == "don't stop l’amour state-of-the-art")
        #expect(NativeTextFinalizer.applySpokenFormatting(
            "Hello, new line world!",
            punctuation: .automatic
        ) == "Hello,\nworld!")
    }
}
