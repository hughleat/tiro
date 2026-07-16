import Foundation

enum RecoveryAction: Equatable {
    case openMicrophoneSettings
    case openAccessibilitySettings
    case openModels
    case retryWorker
    case retryTranscription
}

struct RecoveryPresentation: Equatable {
    let title: String
    let detail: String
    let action: RecoveryAction
}

enum RecoveryCategory {
    case microphonePermission
    case microphoneUnavailable
    case accessibility
    case missingModel
    case workerUnavailable
    case transcription
}

enum ErrorRecovery {
    static func presentation(for category: RecoveryCategory) -> RecoveryPresentation {
        switch category {
        case .microphonePermission:
            return RecoveryPresentation(
                title: "Microphone Access Needed",
                detail: "Allow Tiro to use the microphone, then try dictating again.",
                action: .openMicrophoneSettings
            )
        case .microphoneUnavailable:
            return RecoveryPresentation(
                title: "No Microphone Available",
                detail: "Connect or select a microphone, then try recording again.",
                action: .retryTranscription
            )
        case .accessibility:
            return RecoveryPresentation(
                title: "Accessibility Access Needed",
                detail: "Allow Tiro to control your Mac so the shortcut and automatic paste can work.",
                action: .openAccessibilitySettings
            )
        case .missingModel:
            return RecoveryPresentation(
                title: "No Model Available",
                detail: "Download and select a transcription model before dictating.",
                action: .openModels
            )
        case .workerUnavailable:
            return RecoveryPresentation(
                title: "Tiro Could Not Start",
                detail: "The local transcription service is unavailable. Try starting it again.",
                action: .retryWorker
            )
        case .transcription:
            return RecoveryPresentation(
                title: "Transcription Failed",
                detail: "Tiro could not transcribe this recording. Try recording it again.",
                action: .retryTranscription
            )
        }
    }

    static func presentation(for error: Error, microphoneAuthorized: Bool = false) -> RecoveryPresentation {
        presentation(for: category(for: error, microphoneAuthorized: microphoneAuthorized))
    }

    private static func category(for error: Error, microphoneAuthorized: Bool) -> RecoveryCategory {
        if error is HotkeyError {
            return .accessibility
        }
        if let pasteError = error as? PasteCoordinator.PasteError {
            switch pasteError {
            case .couldNotCreateKeyboardEvent, .keyboardEventRejected:
                return .accessibility
            default:
                return .transcription
            }
        }
        if let recorderError = error as? RecorderError {
            switch recorderError {
            case .noInput:
                return microphoneAuthorized ? .microphoneUnavailable : .microphonePermission
            case .notRecording, .emptyRecording:
                return .transcription
            }
        }
        if let workerError = error as? WorkerError {
            switch workerError {
            case .runtimeMissing, .unavailable:
                return .workerUnavailable
            case .invalidResponse:
                return .transcription
            case .server:
                break
            }
        }

        let message = (error as? LocalizedError)?.errorDescription?.lowercased()
            ?? error.localizedDescription.lowercased()
        if message.contains("microphone") && (message.contains("permission") || message.contains("access")) {
            return .microphonePermission
        }
        if message.contains("accessibility") || message.contains("automatic paste") {
            return .accessibility
        }
        if message.contains("model") && (message.contains("not installed") || message.contains("no model")) {
            return .missingModel
        }
        if message.contains("worker did not start") || message.contains("runtime is missing") {
            return .workerUnavailable
        }
        return .transcription
    }
}
