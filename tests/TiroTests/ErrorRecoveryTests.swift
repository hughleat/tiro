import Foundation
import Testing
@testable import Tiro

struct ErrorRecoveryTests {
    @Test(arguments: [
        (RecoveryCategory.microphonePermission, RecoveryAction.openMicrophoneSettings),
        (.microphoneUnavailable, .retryTranscription),
        (.accessibility, .openAccessibilitySettings),
        (.missingModel, .openModels),
        (.workerUnavailable, .retryWorker),
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
        #expect(ErrorRecovery.presentation(for: WorkerError.runtimeMissing("python")).action == .retryWorker)
        #expect(ErrorRecovery.presentation(for: WorkerError.server("Model is not installed.")).action == .openModels)
        #expect(ErrorRecovery.presentation(for: WorkerError.invalidResponse).action == .retryTranscription)
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
