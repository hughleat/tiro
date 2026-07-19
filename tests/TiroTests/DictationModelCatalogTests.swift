import Foundation
import Testing
@testable import Tiro

struct DictationModelCatalogTests {
    @Test
    func catalogContainsNativeAndSystemModelsWithStableKeys() {
        #expect(DictationModel.catalog.map(\.key) == [
            "apple-speech",
            "coreml-compact",
            "coreml-parakeet-v2",
            "coreml-parakeet-v3",
            "coreml-whisper-tiny-english",
            "coreml-whisper-base-english",
            "coreml-whisper-small-english",
            "coreml-whisper-tiny",
            "coreml-whisper-base",
            "coreml-whisper-small",
            "coreml-whisper-distil-large-v3",
            "coreml-whisper-large-v3",
            "coreml-whisper-turbo",
        ])
        #expect(DictationModel.appleSpeech.provisioning == .systemManaged)
        #expect(DictationModel.appleSpeech.downloadSizeBytes == nil)
        #expect(DictationModel.catalog.dropFirst().allSatisfy {
            ($0.downloadSizeBytes ?? 0) > 0
        })
    }

    @Test
    func modelFamiliesExposeTheirActualLanguageControls() {
        #expect(DictationModel.catalog[0].languageSupport == .selectable)
        #expect(DictationModel.catalog[1].languageSupport == .english)
        #expect(DictationModel.catalog[2].languageSupport == .english)
        #expect(DictationModel.catalog[3].languageSupport == .automatic)
        #expect(
            DictationModel.catalog[4...6].allSatisfy {
                $0.languageSupport == .english
            }
        )
        #expect(
            DictationModel.catalog.dropFirst(7).allSatisfy {
                $0.languageSupport == .selectable
            }
        )
    }

    @Test
    func whisperLanguagesUseExpectedCodes() {
        #expect(DictationLanguage.auto.whisperCode == nil)
        #expect(DictationLanguage.english.whisperCode == "en")
        #expect(DictationLanguage.cantonese.whisperCode == "yue")
        #expect(DictationLanguage.chinese.whisperCode == "zh")
        #expect(DictationLanguage.filipino.whisperCode == "tl")
        #expect(DictationLanguage.english.appleLocaleIdentifier.hasPrefix("en"))
    }
}
