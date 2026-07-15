import Foundation
import ServiceManagement

enum LoginItemManager {
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.tiro.dictation.plist")

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: file.path)
            || SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            try unregisterLegacyService()
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }

        let propertyList: [String: Any] = [
            "Label": "local.tiro.dictation",
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
        try? unregisterLegacyService()
    }

    private static func unregisterLegacyService() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            try SMAppService.mainApp.unregister()
        default:
            break
        }
    }
}
