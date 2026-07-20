import Darwin
import Foundation

public enum TiroCommandSocketPath {
    private static let privateDirectoryName = "Tiro"

    public static func defaultURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["TIRO_COMMAND_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let preferred = cache
                .appendingPathComponent("Tiro", isDirectory: true)
                .appendingPathComponent("command-v1.sock")
            if preferred.path.utf8.count <= TiroProtocolLimits.maximumSocketPathBytes {
                return preferred
            }
        }

        let temporary = environment["TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? fileManager.temporaryDirectory
        return temporary
            .appendingPathComponent("\(privateDirectoryName)-\(geteuid())", isDirectory: true)
            .appendingPathComponent("command-v1.sock")
    }

    public static func validate(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw TiroSocketError.invalidSocketPath
        }
        guard !url.path.utf8.contains(0),
              url.path.utf8.count <= TiroProtocolLimits.maximumSocketPathBytes else {
            throw TiroSocketError.invalidSocketPath
        }
        guard isDedicatedDirectory(url.deletingLastPathComponent()) else {
            throw TiroSocketError.unsafeSocketDirectory
        }
    }

    private static func isDedicatedDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == privateDirectoryName
            || name == "\(privateDirectoryName)-\(geteuid())"
    }
}
