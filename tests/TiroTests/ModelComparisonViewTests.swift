import AppKit
import Testing
@testable import Tiro

struct ModelComparisonViewTests {
    @Test
    func historyLoadingStatesDistinguishFailureFromEmptyHistory() {
        let empty = ModelComparisonHistoryLoadState.loaded(entryCount: 0)
        #expect(empty.message == "No saved recordings are available.")
        #expect(empty.pickerToolTip == "No saved recordings are available")
        #expect(!empty.canRetry)

        let failed = ModelComparisonHistoryLoadState.failed("Store unavailable")
        #expect(failed.message == "Could not load recordings.\nStore unavailable")
        #expect(failed.pickerToolTip == "Could not load recordings. Retry to try again.")
        #expect(failed.canRetry)
    }

    @Test @MainActor
    func resultUsesAppKitsConfiguredScrollableTextView() throws {
        _ = NSApplication.shared
        let result = ComparisonResultView(
            name: "Parakeet Compact",
            seconds: 0.05,
            transcript: "The comparison transcript is visible.",
            error: nil
        )
        let scrollView = try #require(
            result.arrangedSubviews.compactMap { $0 as? NSScrollView }.first
        )
        let textView = try #require(scrollView.documentView as? NSTextView)
        let textContainer = try #require(textView.textContainer)
        let layoutManager = try #require(textView.layoutManager)

        result.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        result.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let glyphBounds = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )

        #expect(textView.string == "The comparison transcript is visible.")
        #expect(textView.enclosingScrollView === scrollView)
        #expect(textContainer.widthTracksTextView)
        #expect(textView.isVerticallyResizable)
        #expect(scrollView.frame.width > 0)
        #expect(scrollView.frame.height > 0)
        #expect(textContainer.containerSize.width > 0)
        #expect(glyphRange.length > 0)
        #expect(glyphBounds.width > 0)
        #expect(glyphBounds.height > 0)
    }
}
