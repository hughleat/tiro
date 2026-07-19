import AppKit
import Foundation
import Testing
@testable import Tiro

struct ErrorRecoveryTests {
    @Test @MainActor
    func acceptedPasteWithoutAccessibilityConfirmationIsStillDispatched() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [0]
        )

        let result = try await coordinator.paste(
            "dictated text",
            to: PasteDestinationStub(consumptionConfirmed: false)
        )

        #expect(result == .dispatched)
        #expect(pasteboard.string == "dictated text")
    }

    @Test @MainActor
    func confirmedPasteRestoresPreviousClipboard() async throws {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .accepted },
            confirmationDelays: [0]
        )

        let result = try await coordinator.paste(
            "dictated text",
            to: PasteDestinationStub(consumptionConfirmed: true)
        )

        #expect(result == .confirmed)
        #expect(pasteboard.string == "previous clipboard")
    }

    @Test @MainActor
    func rejectedPasteEventStillThrows() async {
        let pasteboard = makePasteboard(containing: "previous clipboard")
        let coordinator = PasteCoordinator(
            pasteboard: pasteboard,
            eventDispatcher: { _ in .rejected }
        )

        await #expect(throws: PasteCoordinator.PasteError.self) {
            try await coordinator.paste(
                "dictated text",
                to: PasteDestinationStub(consumptionConfirmed: false)
            )
        }
    }

    @MainActor
    private func makePasteboard(containing text: String) -> PasteboardStub {
        let pasteboard = PasteboardStub()
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    @Test(arguments: [
        (RecoveryCategory.microphonePermission, RecoveryAction.openMicrophoneSettings),
        (.speechRecognitionPermission, .openSpeechRecognitionSettings),
        (.microphoneUnavailable, .retryTranscription),
        (.accessibility, .openAccessibilitySettings),
        (.missingModel, .openModels),
        (.appleSpeechUnavailable, .openModels),
        (.modelServiceUnavailable, .retryModels),
        (.transcription, .retryTranscription),
    ])
    func categoryHasExpectedAction(category: RecoveryCategory, action: RecoveryAction) {
        #expect(ErrorRecovery.presentation(for: category).action == action)
    }

    @Test
    func knownErrorsMapToRecoveryActions() {
        #expect(ErrorRecovery.presentation(for: HotkeyError.accessibilityRequired).action == .openAccessibilitySettings)
        #expect(ErrorRecovery.presentation(for: RecorderError.noInput).action == .openMicrophoneSettings)
        #expect(ErrorRecovery.presentation(for: RecorderError.noInput, microphoneAuthorized: true).action == .retryTranscription)
        #expect(ErrorRecovery.presentation(for: RecorderError.emptyRecording).action == .retryTranscription)
        #expect(
            ErrorRecovery.presentation(
                for: TiroError.message("Speech Recognition permission is required.")
            ).action == .openSpeechRecognitionSettings
        )
        #expect(
            ErrorRecovery.presentation(
                for: TiroError.message("On-device Apple Speech is unavailable.")
            ).action == .openModels
        )
        #expect(ErrorRecovery.presentation(for: TiroError.message("Model is not installed.")).action == .openModels)
        #expect(ErrorRecovery.presentation(for: TiroError.message("Could not decode audio.")).action == .retryTranscription)
        #expect(ErrorRecovery.presentation(for: PasteCoordinator.PasteError.keyboardEventRejected).action == .openAccessibilitySettings)
        #expect(ErrorRecovery.presentation(for: PasteCoordinator.PasteError.secureDestination).action == .retryTranscription)
    }

    @Test
    func everyOverlayStateHasAConciseAnnouncement() {
        let states: [OverlayState] = [
            .recording, .startingUp, .transcribing, .pasted, .pasteSent, .copied, .pasteFailed, .error,
        ]
        for state in states {
            #expect(!state.announcement.isEmpty)
            #expect(state.announcement.count < 60)
        }
    }
}

@MainActor
private final class PasteboardStub: PasteboardAccess {
    private(set) var changeCount = 0
    private(set) var pasteboardItems: [NSPasteboardItem]? = []

    var string: String? {
        pasteboardItems?.first?.string(forType: .string)
    }

    @discardableResult
    func clearContents() -> Int {
        changeCount += 1
        pasteboardItems = []
        return changeCount
    }

    func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool {
        let item = NSPasteboardItem()
        item.setString(string, forType: dataType)
        pasteboardItems = [item]
        changeCount += 1
        return true
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        pasteboardItems = objects.compactMap { $0 as? NSPasteboardItem }
        changeCount += 1
        return pasteboardItems?.count == objects.count
    }
}

@MainActor
private struct PasteDestinationStub: PasteDestination {
    let consumptionConfirmed: Bool

    var isAvailable: Bool { true }
    var isSecure: Bool { false }
    var isFrontmost: Bool { true }
    var isFocused: Bool { true }
    var isCurrentPasteTargetAtDispatch: Bool { true }

    func restore() async -> Bool { true }

    func observePasteTarget(afterInserting text: String) -> PasteObservation {
        PasteObservation(expectedValue: text, expectedCharacterCount: nil)
    }

    func hasConsumedPaste(since observation: PasteObservation) -> Bool {
        consumptionConfirmed
    }
}
