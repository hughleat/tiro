import AppKit
import ApplicationServices
import AVFoundation
import Speech

@MainActor
enum DiagnosticsReport {
    static func text(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let release = bundle.object(forInfoDictionaryKey: "TiroReleaseTag") as? String ?? "untagged"
        return """
        Tiro Diagnostics
        Version: \(version) (\(build))
        Release: \(release)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architecture)
        Model: \(DictationModel.selected.name) (\(DictationModel.selected.key))
        Microphone: \(microphoneStatus)
        Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")
        Speech Recognition: \(speechStatus)
        Auto-paste: \(defaults.bool(forKey: "autoPaste") ? "enabled" : "disabled")
        Recording feedback: \(defaults.bool(forKey: "soundFeedback") ? "enabled" : "disabled")
        Launch at login: \(LoginItemManager.isEnabled ? "enabled" : "disabled")

        This report excludes transcripts, audio, clipboard contents, vocabulary, file paths, and application names.
        """
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "allowed"
        case .denied: return "not allowed"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }

    private static var speechStatus: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "allowed"
        case .denied: return "not allowed"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }
}
