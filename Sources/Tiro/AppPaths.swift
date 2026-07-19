import Foundation

enum AppPaths {
    struct MigrationReport {
        let sources: [URL]
        let copiedItems: [String]
        let skippedItems: [String]

        var didCopyData: Bool { !copiedItems.isEmpty }
    }

    struct MigrationError: LocalizedError {
        let failures: [String]

        var errorDescription: String? {
            "Legacy migration left unresolved items: \(failures.joined(separator: "; "))"
        }
    }

    private static let fileManager = FileManager.default
    private static let migrationMarkerName = ".legacy-project-data-migrated-v4"
    private static let knownProjectRootName = ".legacy-project-root"
    private static let migratableDataItems = [
        "audio",
        "history.jsonl",
        "history.jsonl.bak",
        "profiles.json",
        "retention.json",
        "privacy.json",
        "suggestions.json",
        "snippets.json",
        "vocabulary.json",
        "vocabulary.txt",
    ]

    private static let rawApplicationSupportDirectory: URL = {
        if let configuredPath = ProcessInfo.processInfo.environment["TIRO_DATA_DIR"] {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiro", isDirectory: true)
    }()

    /// The checkout root used only by development builds and legacy migration.
    static let projectRoot: URL = {
        if let configuredPath = ProcessInfo.processInfo.environment["TIRO_PROJECT_ROOT"] {
            let root = URL(fileURLWithPath: configuredPath, isDirectory: true)
            persistProjectRootIfUsable(root)
            return root
        }

        let bundleParent = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        for candidate in [bundleParent, currentDirectory] where isProjectRoot(candidate) {
            persistProjectRootIfUsable(candidate)
            return candidate
        }

        let savedRootFile = rawApplicationSupportDirectory
            .appendingPathComponent(knownProjectRootName)
        if let savedPath = try? String(contentsOf: savedRootFile, encoding: .utf8) {
            let candidate = URL(
                fileURLWithPath: savedPath.trimmingCharacters(in: .whitespacesAndNewlines),
                isDirectory: true
            )
            if isProjectRoot(candidate) {
                return candidate
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let commonCandidates = [
            home.appendingPathComponent("Documents/code/voice-to-text", isDirectory: true),
            home.appendingPathComponent("Developer/voice-to-text", isDirectory: true),
            home.appendingPathComponent("Code/voice-to-text", isDirectory: true),
        ]
        if let candidate = commonCandidates.first(where: isProjectRoot) {
            persistProjectRootIfUsable(candidate)
            return candidate
        }

        return currentDirectory
    }()

    /// Evaluating a mutable path attempts the copy-only migration once per process.
    static let migrationResult: Result<MigrationReport, Error> = Result {
        try migrateLegacyProjectDataIfNeeded()
    }

    static var applicationSupportDirectory: URL {
        _ = migrationResult
        return rawApplicationSupportDirectory
    }

    static var dataDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("data", isDirectory: true)
    }

    static var coreMLModelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Models/coreml", isDirectory: true)
    }

    static var historyFile: URL {
        dataDirectory.appendingPathComponent("history.jsonl")
    }

    static var recordingsDirectory: URL {
        dataDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    static var transientRecordingsDirectory: URL {
        dataDirectory.appendingPathComponent("transient-audio", isDirectory: true)
    }

    static var privacyFile: URL {
        dataDirectory.appendingPathComponent("privacy.json")
    }

    static var profilesFile: URL {
        dataDirectory.appendingPathComponent("profiles.json")
    }

    static var snippetsFile: URL {
        dataDirectory.appendingPathComponent("snippets.json")
    }

    static var suggestionsFile: URL {
        dataDirectory.appendingPathComponent("suggestions.json")
    }

    static var legacyRetentionFile: URL {
        dataDirectory.appendingPathComponent("retention.json")
    }

    static var vocabularyFile: URL {
        dataDirectory.appendingPathComponent("vocabulary.json")
    }

    static var legacyVocabularyFile: URL {
        dataDirectory.appendingPathComponent("vocabulary.txt")
    }

    /// Merges known checkout data without overwriting or deleting source files.
    @discardableResult
    static func migrateLegacyProjectDataIfNeeded() throws -> MigrationReport {
        let marker = rawApplicationSupportDirectory.appendingPathComponent(migrationMarkerName)
        if fileManager.fileExists(atPath: marker.path) {
            return MigrationReport(sources: [], copiedItems: [], skippedItems: [])
        }

        let root = projectRoot
        let legacyData = root.appendingPathComponent("data", isDirectory: true)
        var sources: [URL] = []
        var copied: [String] = []
        var skipped: [String] = []
        var failures: [String] = []

        let dataDestination = rawApplicationSupportDirectory
            .appendingPathComponent("data", isDirectory: true)
        if isDirectory(legacyData), legacyData.standardizedFileURL != dataDestination.standardizedFileURL {
            sources.append(legacyData)
            for name in migratableDataItems {
                mergeItem(
                    from: legacyData.appendingPathComponent(name),
                    to: dataDestination.appendingPathComponent(name),
                    label: "data/\(name)",
                    copied: &copied,
                    skipped: &skipped,
                    failures: &failures
                )
            }
        }

        guard !sources.isEmpty else {
            return MigrationReport(sources: [], copiedItems: [], skippedItems: [])
        }
        guard failures.isEmpty else {
            throw MigrationError(failures: failures)
        }

        try fileManager.createDirectory(
            at: rawApplicationSupportDirectory,
            withIntermediateDirectories: true
        )
        let sourceList = sources.map(\.path).joined(separator: "\n")
        try ("Copied from:\n\(sourceList)\n").write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
        return MigrationReport(sources: sources, copiedItems: copied, skippedItems: skipped)
    }

    private static func mergeItem(
        from source: URL,
        to destination: URL,
        label: String,
        copied: inout [String],
        skipped: inout [String],
        failures: inout [String]
    ) {
        let sourceExists = fileManager.fileExists(atPath: source.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) != nil
        guard sourceExists else { return }

        let sourceType: FileAttributeType
        do {
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                failures.append("\(label): source type is unavailable")
                return
            }
            sourceType = type
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
            return
        }

        let sourceIsDirectory = sourceType == .typeDirectory
        if let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path),
           let destinationType = destinationAttributes[.type] as? FileAttributeType {
            let destinationIsDirectory = destinationType == .typeDirectory
            if sourceIsDirectory && destinationIsDirectory {
                do {
                    let children = try fileManager.contentsOfDirectory(
                        at: source,
                        includingPropertiesForKeys: nil
                    )
                    for child in children {
                        mergeItem(
                            from: child,
                            to: destination.appendingPathComponent(child.lastPathComponent),
                            label: "\(label)/\(child.lastPathComponent)",
                            copied: &copied,
                            skipped: &skipped,
                            failures: &failures
                        )
                    }
                } catch {
                    failures.append("\(label): \(error.localizedDescription)")
                }
            } else if sourceIsDirectory != destinationIsDirectory {
                failures.append("\(label): destination type conflicts with source")
            } else {
                skipped.append(label)
            }
            return
        }

        do {
            if sourceIsDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                let children = try fileManager.contentsOfDirectory(
                    at: source,
                    includingPropertiesForKeys: nil
                )
                if children.isEmpty {
                    copied.append(label)
                }
                for child in children {
                    mergeItem(
                        from: child,
                        to: destination.appendingPathComponent(child.lastPathComponent),
                        label: "\(label)/\(child.lastPathComponent)",
                        copied: &copied,
                        skipped: &skipped,
                        failures: &failures
                    )
                }
            } else {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                copied.append(label)
            }
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isProjectRoot(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
            && fileManager.fileExists(
                atPath: url.appendingPathComponent("Sources/Tiro/AppDelegate.swift").path
            )
    }

    private static func persistProjectRootIfUsable(_ root: URL) {
        guard isProjectRoot(root) else { return }
        do {
            try fileManager.createDirectory(
                at: rawApplicationSupportDirectory,
                withIntermediateDirectories: true
            )
            try (root.standardizedFileURL.path + "\n").write(
                to: rawApplicationSupportDirectory.appendingPathComponent(knownProjectRootName),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog("Could not remember Tiro development checkout: %@", error.localizedDescription)
        }
    }
}
