import Foundation
import Testing
@testable import Tiro

struct DictationModelCatalogTests {
    @Test
    func catalogContainsOnlyNativeCoreMLModelsWithStableKeys() {
        #expect(DictationModel.catalog.map(\.key) == [
            "coreml-compact",
            "coreml-parakeet-v2",
            "coreml-parakeet-v3",
            "coreml-whisper-tiny",
            "coreml-whisper-base",
            "coreml-whisper-small",
            "coreml-whisper-large-v3",
            "coreml-whisper-turbo",
        ])
        #expect(DictationModel.catalog.allSatisfy { $0.downloadSizeBytes > 0 })
    }

    @Test
    func modelFamiliesExposeTheirActualLanguageControls() {
        #expect(DictationModel.catalog[0].languageSupport == .english)
        #expect(DictationModel.catalog[1].languageSupport == .english)
        #expect(DictationModel.catalog[2].languageSupport == .automatic)
        #expect(
            DictationModel.catalog.dropFirst(3).allSatisfy {
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
    }
}
