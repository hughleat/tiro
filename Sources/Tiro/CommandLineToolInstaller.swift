import AppKit
import Foundation

enum CommandLineToolState: Equatable {
    case available
    case installed
    case needsRepair
    case conflict
    case unavailable

    var detail: String {
        switch self {
        case .available: "Install the tiro command in /usr/local/bin."
        case .installed: "The tiro command is installed and follows app updates."
        case .needsRepair: "The installed tiro command points to an older app location."
        case .conflict:
            "Another file already exists at /usr/local/bin/tiro. Tiro will not change it."
        case .unavailable: "The command-line helper is missing from this build."
        }
    }
}

struct CommandLineToolInstaller {
    static let defaultLinkURL = URL(fileURLWithPath: "/usr/local/bin/tiro")

    let helperURL: URL
    let linkURL: URL
    private let fileManager: FileManager

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        linkURL: URL = Self.defaultLinkURL,
        fileManager: FileManager = .default
    ) {
        helperURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("tiro")
        self.linkURL = linkURL
        self.fileManager = fileManager
    }

    var state: CommandLineToolState {
        let ownership = linkOwnership
        if case .conflict = ownership {
            return .conflict
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            return .unavailable
        }
        switch ownership {
        case .absent:
            return .available
        case .tiro(_, let resolved):
            return resolved == helperURL.standardizedFileURL ? .installed : .needsRepair
        case .conflict:
            return .conflict
        }
    }

    func install() throws {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw CommandLineToolError.helperMissing
        }
        switch linkOwnership {
        case .absent:
            try runAsAdministrator(
                "/bin/mkdir -p \(shellQuoted(linkURL.deletingLastPathComponent().path))"
                    + " && /bin/ln -s \(shellQuoted(helperURL.path)) \(shellQuoted(linkURL.path))"
            )
        case .tiro(_, let resolved) where resolved == helperURL.standardizedFileURL:
            return
        case .tiro(let destination, _):
            try runAsAdministrator(replaceCommand(expectedDestination: destination))
        case .conflict:
            throw CommandLineToolError.pathConflict
        }
        guard state == .installed else {
            throw CommandLineToolError.installFailed(
                "The file at \(linkURL.path) changed before Tiro could update it."
            )
        }
    }

    func uninstall() throws {
        switch linkOwnership {
        case .absent:
            return
        case .tiro(let destination, _):
            try runAsAdministrator(removeCommand(expectedDestination: destination))
        case .conflict:
            throw CommandLineToolError.pathConflict
        }
        guard case .absent = linkOwnership else {
            throw CommandLineToolError.installFailed(
                "The file at \(linkURL.path) changed before Tiro could remove it."
            )
        }
    }

    private var linkOwnership: LinkOwnership {
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: linkURL.path
        ) else {
            return fileManager.fileExists(atPath: linkURL.path) ? .conflict : .absent
        }
        let resolved = URL(
            fileURLWithPath: destination,
            relativeTo: linkURL.deletingLastPathComponent()
        ).standardizedFileURL
        return isTiroBundledHelper(resolved)
            ? .tiro(destination: destination, resolved: resolved)
            : .conflict
    }

    private func isTiroBundledHelper(_ url: URL) -> Bool {
        guard url.lastPathComponent == "tiro",
              url.deletingLastPathComponent().lastPathComponent == "Helpers" else {
            return false
        }
        let contentsURL = url.deletingLastPathComponent().deletingLastPathComponent()
        let appURL = contentsURL.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents",
              appURL.lastPathComponent == "Tiro.app" else {
            return false
        }
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let plist = object as? [String: Any] else {
            return false
        }
        return plist["CFBundleIdentifier"] as? String == "local.tiro.dictation"
    }

    private func replaceCommand(expectedDestination: String) -> String {
        guardedSymlinkCommand(expectedDestination: expectedDestination) {
            "/bin/rm \(shellQuoted(linkURL.path))"
                + " && /bin/ln -s \(shellQuoted(helperURL.path)) \(shellQuoted(linkURL.path))"
        }
    }

    private func removeCommand(expectedDestination: String) -> String {
        guardedSymlinkCommand(expectedDestination: expectedDestination) {
            "/bin/rm \(shellQuoted(linkURL.path))"
        }
    }

    private func guardedSymlinkCommand(
        expectedDestination: String,
        action: () -> String
    ) -> String {
        "if [ -L \(shellQuoted(linkURL.path)) ]"
            + " && [ \"$(/usr/bin/readlink \(shellQuoted(linkURL.path)))\" = "
            + "\(shellQuoted(expectedDestination)) ]; then \(action()); else exit 73; fi"
    }

    private func runAsAdministrator(_ command: String) throws {
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        var error: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
            if (error?[NSAppleScript.errorNumber] as? Int) == -128 {
                throw CancellationError()
            }
            throw CommandLineToolError.installFailed(
                error?[NSAppleScript.errorMessage] as? String ?? "Administrator authorization failed."
            )
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private enum LinkOwnership {
    case absent
    case tiro(destination: String, resolved: URL)
    case conflict
}

enum CommandLineToolError: LocalizedError {
    case helperMissing
    case pathConflict
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing: "This Tiro build does not contain the command-line helper."
        case .pathConflict:
            "Tiro will not change /usr/local/bin/tiro because it does not belong to Tiro."
        case .installFailed(let detail): "The tiro command could not be installed. \(detail)"
        }
    }
}
