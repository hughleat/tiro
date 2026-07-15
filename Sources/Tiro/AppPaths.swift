import Foundation

enum AppPaths {
    static let projectRoot: URL = {
        if let configuredPath = ProcessInfo.processInfo.environment["TIRO_PROJECT_ROOT"] {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }

        let bundleParent = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: bundleParent.appendingPathComponent("app.py").path) {
            return bundleParent
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }()

    static var historyFile: URL {
        projectRoot.appendingPathComponent("data/history.jsonl")
    }

    static var vocabularyFile: URL {
        projectRoot.appendingPathComponent("data/vocabulary.txt")
    }

    static var workerLog: URL {
        projectRoot.appendingPathComponent("data/worker.log")
    }
}
