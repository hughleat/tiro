import Foundation
import Testing
@testable import TiroRecognition

struct AppleSpeechEngineTests {
    @Test
    func optionsLimitContextToAppleMaximum() {
        let options = AppleSpeechOptions(
            localeIdentifier: "en-GB",
            contextualStrings: (0..<120).map { "Term \($0)" }
        )

        #expect(options.localeIdentifier == "en-GB")
        #expect(options.contextualStrings.count == 100)
        #expect(options.contextualStrings.last == "Term 99")
    }

    @Test
    func availabilitySeparatesPermissionFromUsability() {
        let permission = AppleSpeechAvailability(state: .permissionRequired)
        let unavailable = AppleSpeechAvailability(state: .unavailable)
        let ready = AppleSpeechAvailability(state: .ready)

        #expect(!permission.permissionGranted)
        #expect(!permission.usable)
        #expect(unavailable.permissionGranted)
        #expect(!unavailable.usable)
        #expect(ready.permissionGranted)
        #expect(ready.usable)
    }

    @Test
    func engineForwardsFileLocaleAndVocabulary() async throws {
        let runtime = AppleSpeechRuntimeStub()
        let engine = AppleSpeechEngine(runtime: runtime)
        let audioURL = URL(fileURLWithPath: "/tmp/tiro-apple-speech.wav")
        let options = AppleSpeechOptions(
            localeIdentifier: "en-GB",
            contextualStrings: ["Janne", "Tiro"]
        )

        let result = try await engine.transcribe(audioURL, options: options)

        #expect(await runtime.audioURL == audioURL)
        #expect(await runtime.options == options)
        #expect(result.text == "Apple transcription")
        #expect(result.audioSeconds == 3)
        #expect(result.transcriptionSeconds == 0.2)
    }

    @Test
    func localeResolverPrefersExactThenCurrentRegion() {
        let supported = Set([
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
            Locale(identifier: "fr-FR"),
        ])

        #expect(
            AppleSpeechLocaleResolver.resolve(
                requested: Locale(identifier: "en_GB"),
                supported: supported
            )?.identifier == "en_GB"
        )
        #expect(
            AppleSpeechLocaleResolver.resolve(
                requested: Locale(identifier: "en"),
                supported: supported,
                current: Locale(identifier: "en-GB")
            )?.region?.identifier == "GB"
        )
        #expect(
            AppleSpeechLocaleResolver.resolve(
                requested: Locale(identifier: "de"),
                supported: supported
            ) == nil
        )
    }
}

private actor AppleSpeechRuntimeStub: AppleSpeechRuntime {
    private(set) var audioURL: URL?
    private(set) var options: AppleSpeechOptions?

    func transcribe(
        _ audioURL: URL,
        options: AppleSpeechOptions
    ) -> AppleSpeechTranscript {
        self.audioURL = audioURL
        self.options = options
        return AppleSpeechTranscript(
            text: "Apple transcription",
            audioSeconds: 3,
            transcriptionSeconds: 0.2
        )
    }
}
