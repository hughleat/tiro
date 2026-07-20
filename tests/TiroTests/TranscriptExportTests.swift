import Foundation
import Testing
@testable import Tiro
import TiroRecognition

struct TranscriptExportTests {
    @Test
    func exportsSpeakerSubtitlesAndStructuredJSON() throws {
        let segments = [
            TranscriptSegment(
                text: "Hello",
                startSeconds: 1.25,
                endSeconds: 2.5,
                speakerID: "speaker-a"
            ),
            TranscriptSegment(
                text: "Hi",
                startSeconds: 2.75,
                endSeconds: 3,
                speakerID: "speaker-b"
            ),
        ]
        let srt = String(decoding: try TranscriptExport.data(
            format: .srt,
            text: "Speaker 1: Hello",
            segments: segments
        ), as: UTF8.self)
        #expect(srt.contains("00:00:01,250 --> 00:00:02,500"))
        #expect(srt.contains("Speaker 1: Hello"))
        #expect(srt.contains("Speaker 2: Hi"))

        let json = try #require(JSONSerialization.jsonObject(with: TranscriptExport.data(
            format: .json,
            text: "Hello",
            segments: segments
        )) as? [String: Any])
        #expect(json["schema"] as? Int == 1)
        #expect((json["segments"] as? [[String: Any]])?.count == 2)

        let markdown = String(decoding: try TranscriptExport.data(
            format: .markdown,
            text: "Hello",
            segments: segments
        ), as: UTF8.self)
        #expect(markdown.contains("## Speaker 1\n\nHello"))
        #expect(markdown.contains("## Speaker 2\n\nHi"))
    }

    @Test
    func subtitleExportRequiresTimestamps() {
        #expect(throws: TranscriptExportError.self) {
            try TranscriptExport.data(format: .vtt, text: "Hello", segments: [])
        }
    }

}
