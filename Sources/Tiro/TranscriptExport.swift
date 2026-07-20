import Foundation
import TiroRecognition

enum TranscriptExportFormat: String, CaseIterable {
    case text = "Plain Text"
    case markdown = "Markdown"
    case json = "JSON"
    case srt = "SubRip Subtitles"
    case vtt = "WebVTT Subtitles"

    var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        case .json: "json"
        case .srt: "srt"
        case .vtt: "vtt"
        }
    }
}

enum TranscriptExport {
    static func data(
        format: TranscriptExportFormat,
        text: String,
        segments: [TranscriptSegment]
    ) throws -> Data {
        switch format {
        case .text:
            return Data((text + trailingNewline(for: text)).utf8)
        case .markdown:
            return Data(markdown(text: text, segments: segments).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(Document(text: text, segments: segments))
            data.append(0x0A)
            return data
        case .srt:
            return Data((try subtitleText(segments: segments, webVTT: false)).utf8)
        case .vtt:
            return Data((try subtitleText(segments: segments, webVTT: true)).utf8)
        }
    }

    private static func markdown(text: String, segments: [TranscriptSegment]) -> String {
        let speakerIDs = Array(Set(segments.compactMap(\.speakerID))).sorted()
        guard !speakerIDs.isEmpty else {
            return "# Transcription\n\n" + text + trailingNewline(for: text)
        }
        let labels = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)")
        })
        var blocks: [String] = []
        var activeSpeaker: String?
        for segment in segments {
            let label = segment.speakerID.flatMap { labels[$0] } ?? "Transcript"
            if label != activeSpeaker {
                blocks.append("## \(label)")
                activeSpeaker = label
            }
            let value = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(value) }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func subtitleText(
        segments: [TranscriptSegment],
        webVTT: Bool
    ) throws -> String {
        let timed = segments.filter { $0.endSeconds > $0.startSeconds }
        guard !timed.isEmpty else { throw TranscriptExportError.timestampsUnavailable }
        let speakerIDs = Array(Set(timed.compactMap(\.speakerID))).sorted()
        let labels = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)")
        })
        let blocks = timed.enumerated().map { index, segment in
            let separator: Character = webVTT ? "." : ","
            let timing = "\(timestamp(segment.startSeconds, separator: separator)) --> "
                + timestamp(segment.endSeconds, separator: separator)
            let body = segment.speakerID.flatMap { labels[$0] }.map {
                "\($0): \(segment.text)"
            } ?? segment.text
            return webVTT
                ? "\(timing)\n\(body)"
                : "\(index + 1)\n\(timing)\n\(body)"
        }
        return (webVTT ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
    }

    private static func timestamp(_ seconds: Double, separator: Character) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
            + String(separator)
            + String(format: "%03d", remainder)
    }

    private static func trailingNewline(for text: String) -> String {
        text.hasSuffix("\n") ? "" : "\n"
    }

    private struct Document: Encodable {
        let schema = 1
        let text: String
        let segments: [TranscriptSegment]
    }
}

enum TranscriptExportError: LocalizedError {
    case timestampsUnavailable

    var errorDescription: String? {
        "This transcription does not contain the timestamps required for subtitle export."
    }
}
