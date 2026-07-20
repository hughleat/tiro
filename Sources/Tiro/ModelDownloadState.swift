import Foundation

enum ManagedModelOperation: Hashable {
    case downloading(progress: Double?)
    case cancelling
    case deleting

    var isDownloading: Bool {
        switch self {
        case .downloading, .cancelling: true
        case .deleting: false
        }
    }

    var isDeleting: Bool {
        if case .deleting = self { return true }
        return false
    }
}

struct ModelDownloadSpace: Hashable {
    static let minimumFreeBytes: Int64 = 2_000_000_000
    static let minimumWorkingBytes: Int64 = 256_000_000

    let downloadBytes: Int64
    let requiredBytes: Int64
    let availableBytes: Int64?

    init(downloadBytes: Int64, availableBytes: Int64?) {
        self.downloadBytes = downloadBytes
        let workingBytes = max(
            Self.minimumWorkingBytes,
            downloadBytes / 10
        )
        requiredBytes = downloadBytes + workingBytes + Self.minimumFreeBytes
        self.availableBytes = availableBytes
    }

    var hasEnoughSpace: Bool {
        guard let availableBytes else { return true }
        return availableBytes >= requiredBytes
    }
}

enum ModelStorageCapacity {
    static func available(at directory: URL) -> Int64? {
        var candidate = directory.standardizedFileURL
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        let values = try? candidate.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
