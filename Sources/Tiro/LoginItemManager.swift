import Foundation
import ServiceManagement

enum LoginItemManager {
    private static let legacyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.tiro.dictation.plist")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || ownsLegacyLaunchAgent()
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enableMainAppService()
            try removeLegacyLaunchAgent()
        } else {
            try disableMainAppService()
            try removeLegacyLaunchAgent()
        }
    }

    private static func enableMainAppService() throws {
        switch SMAppService.mainApp.status {
        case .enabled:
            return
        case .requiresApproval:
            throw LoginItemError.approvalRequired
        case .notRegistered:
            do {
                try SMAppService.mainApp.register()
            } catch {
                throw LoginItemError.registrationFailed(error)
            }
        case .notFound:
            throw LoginItemError.serviceUnavailable
        @unknown default:
            throw LoginItemError.serviceUnavailable
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            return
        case .requiresApproval:
            throw LoginItemError.approvalRequired
        case .notRegistered, .notFound:
            throw LoginItemError.registrationDidNotComplete
        @unknown default:
            throw LoginItemError.registrationDidNotComplete
        }
    }

    private static func disableMainAppService() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw LoginItemError.unregistrationFailed(error)
            }
        case .notRegistered, .notFound:
            return
        @unknown default:
            throw LoginItemError.serviceUnavailable
        }
    }

    private static func removeLegacyLaunchAgent() throws {
        guard FileManager.default.fileExists(atPath: legacyFile.path) else { return }
        guard ownsLegacyLaunchAgent() else {
            throw LoginItemError.unrecognizedLegacyFile(legacyFile)
        }

        do {
            try FileManager.default.removeItem(at: legacyFile)
        } catch {
            throw LoginItemError.legacyCleanupFailed(legacyFile, error)
        }
    }

    private static func ownsLegacyLaunchAgent() -> Bool {
        guard
            let data = try? Data(contentsOf: legacyFile),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            propertyList["Label"] as? String == "local.tiro.dictation",
            let arguments = propertyList["ProgramArguments"] as? [String],
            arguments.count == 2,
            arguments[0] == "/usr/bin/open",
            URL(fileURLWithPath: arguments[1]).lastPathComponent == "Tiro.app"
        else { return false }
        return true
    }
}

private enum LoginItemError: LocalizedError {
    case approvalRequired
    case serviceUnavailable
    case registrationDidNotComplete
    case registrationFailed(Error)
    case unregistrationFailed(Error)
    case legacyCleanupFailed(URL, Error)
    case unrecognizedLegacyFile(URL)

    var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return "Tiro needs approval to launch at login."
        case .serviceUnavailable:
            return "Tiro could not find its login item service."
        case .registrationDidNotComplete:
            return "Tiro's login item registration did not complete."
        case .registrationFailed(let error):
            return "Tiro could not register as a login item: \(error.localizedDescription)"
        case .unregistrationFailed(let error):
            return "Tiro could not remove its login item: \(error.localizedDescription)"
        case .legacyCleanupFailed(let file, let error):
            return "Tiro could not remove the legacy login item at \(file.path): \(error.localizedDescription)"
        case .unrecognizedLegacyFile(let file):
            return "The file at \(file.path) is not a Tiro login item, so Tiro left it untouched."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .approvalRequired:
            return "Open System Settings > General > Login Items, then allow Tiro under Open at Login."
        case .serviceUnavailable, .registrationDidNotComplete:
            return "Move Tiro to Applications, reopen it, and try again."
        case .registrationFailed, .unregistrationFailed:
            return "Open System Settings > General > Login Items, check Tiro's current state, and try again."
        case .legacyCleanupFailed(let file, _):
            return "Remove \(file.path) and try again."
        case .unrecognizedLegacyFile:
            return "Review the existing LaunchAgent manually before changing this setting."
        }
    }
}
