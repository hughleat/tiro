import Darwin
import Foundation

enum PrivateFilePermissions {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    static func ensureDirectory(at url: URL) throws {
        try rejectSymbolicLink(at: url)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: directoryMode)]
        )
        try repairItem(at: url)
    }

    static func ensureFile(at url: URL) throws {
        try ensureDirectory(at: url.deletingLastPathComponent())
        try rejectSymbolicLink(at: url)
        if !itemExists(at: url) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: fileMode)]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try repairItem(at: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(at: url.deletingLastPathComponent())
        try rejectSymbolicLink(at: url)
        try data.write(to: url, options: .atomic)
        try repairItem(at: url)
    }

    static func repairTree(at root: URL) throws {
        try ensureDirectory(at: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { return }

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true || values.isRegularFile == true {
                try repairItem(at: item)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    static func repairItem(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }

        let mode: mode_t
        let flags: Int32
        if values.isDirectory == true {
            mode = directoryMode
            flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        } else if values.isRegularFile == true {
            mode = fileMode
            flags = O_RDONLY | O_NOFOLLOW
        } else {
            return
        }

        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func rejectSymbolicLink(at url: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
