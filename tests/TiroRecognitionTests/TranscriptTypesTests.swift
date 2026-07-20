import Foundation
import Testing
@testable import TiroRecognition

struct TranscriptTypesTests {
    @Test
    func rawTranscriptRoundTripsStructuredSegments() throws {
        let transcript = RawTranscript(
            text: "Hello Janne.",
            model: .parakeetCompactCoreML,
            audioSeconds: 2,
            transcriptionSeconds: 0.1,
            timesFasterThanRealtime: 20,
            segments: [
                TranscriptSegment(
                    text: "Hello Janne.",
                    startSeconds: 0.2,
                    endSeconds: 1.4,
                    speakerID: "S1",
                    words: [
                        TranscriptWord(
                            text: "Hello",
                            startSeconds: 0.2,
                            endSeconds: 0.6
                        ),
                        TranscriptWord(
                            text: "Janne.",
                            startSeconds: 0.8,
                            endSeconds: 1.4
                        ),
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(RawTranscript.self, from: data)

        #expect(decoded == transcript)
    }

    @Test
    func rawTranscriptDecodesLegacyJSONWithoutSegments() throws {
        let data = Data(
            """
            {
              "text": "Legacy transcript",
              "model": "apple-speech",
              "audioSeconds": 2,
              "transcriptionSeconds": 0.5,
              "timesFasterThanRealtime": 4
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(RawTranscript.self, from: data)

        #expect(decoded.text == "Legacy transcript")
        #expect(decoded.model == .appleSpeech)
        #expect(decoded.segments.isEmpty)
    }

    @Test
    func existingInitializerDefaultsToNoSegments() {
        let transcript = RawTranscript(
            text: "Compatible",
            model: .appleSpeech,
            audioSeconds: 1,
            transcriptionSeconds: 0.25,
            timesFasterThanRealtime: 4
        )

        #expect(transcript.segments.isEmpty)
    }
}
