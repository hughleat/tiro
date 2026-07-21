import Foundation
import Testing
@testable import Tiro

struct DiagnosticsReportTests {
    @Test @MainActor
    func reportContainsOnlyAllowListedFields() {
        let report = DiagnosticsReport.text()
        let lines = report.split(whereSeparator: \Character.isNewline).map(String.init)
        let expectedPrefixes = [
            "Tiro Diagnostics",
            "Version:",
            "Release:",
            "macOS:",
            "Architecture:",
            "Model:",
            "Microphone:",
            "Accessibility:",
            "Speech Recognition:",
            "Auto-paste:",
            "Recording feedback:",
            "Launch at login:",
            "This report excludes transcripts, audio, clipboard contents, vocabulary, file paths, and application names.",
        ]
        #expect(lines.count == expectedPrefixes.count)
        for (line, prefix) in zip(lines, expectedPrefixes) {
            #expect(line.hasPrefix(prefix))
        }
    }
}
