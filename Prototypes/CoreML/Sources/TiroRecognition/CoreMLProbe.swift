import Foundation

public struct CoreMLProbeOptions: Equatable, Sendable {
    public let audioURL: URL
    public let modelDirectory: URL
    public let allowDownload: Bool

    public init(audioURL: URL, modelDirectory: URL, allowDownload: Bool) {
        self.audioURL = audioURL
        self.modelDirectory = modelDirectory
        self.allowDownload = allowDownload
    }

    public static func parse(
        arguments: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> CoreMLProbeOptions {
        var audioPath: String?
        var modelRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/Tiro/Models/coreml-prototype")
        var allowDownload = false
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--audio":
                index += 1
                guard index < arguments.count else {
                    throw CoreMLProbeOptionError.missingValue("--audio")
                }
                audioPath = arguments[index]
            case "--model-dir":
                index += 1
                guard index < arguments.count else {
                    throw CoreMLProbeOptionError.missingValue("--model-dir")
                }
                modelRoot = URL(fileURLWithPath: arguments[index])
            case "--download":
                allowDownload = true
            case "--help", "-h":
                throw CoreMLProbeOptionError.helpRequested
            case let unknown:
                throw CoreMLProbeOptionError.unknownArgument(unknown)
            }
            index += 1
        }

        guard let audioPath else {
            throw CoreMLProbeOptionError.missingAudio
        }
        return CoreMLProbeOptions(
            audioURL: URL(fileURLWithPath: audioPath).standardizedFileURL,
            modelDirectory: modelRoot
                .appendingPathComponent("parakeet-tdt-ctc-110m")
                .standardizedFileURL,
            allowDownload: allowDownload
        )
    }
}

public enum CoreMLProbeOptionError: LocalizedError, Equatable {
    case helpRequested
    case missingAudio
    case missingValue(String)
    case unknownArgument(String)

    public var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .missingAudio:
            return "Missing required --audio path."
        case .missingValue(let argument):
            return "Missing value after \(argument)."
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        }
    }
}

public struct CoreMLProbeResult: Codable, Sendable {
    public let transcript: RawTranscript
    public let modelDirectory: String
    public let installedModelBytes: Int64
    public let downloadSeconds: Double
    public let loadSeconds: Double
    public let wallSeconds: Double

    public init(
        transcript: RawTranscript,
        modelDirectory: String,
        installedModelBytes: Int64,
        downloadSeconds: Double,
        loadSeconds: Double,
        wallSeconds: Double
    ) {
        self.transcript = transcript
        self.modelDirectory = modelDirectory
        self.installedModelBytes = installedModelBytes
        self.downloadSeconds = downloadSeconds
        self.loadSeconds = loadSeconds
        self.wallSeconds = wallSeconds
    }
}

public enum DirectorySize {
    public static func bytes(at directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        return files.reduce(into: 0) { total, item in
            guard
                let url = item as? URL,
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else {
                return
            }
            total += Int64(values.fileSize ?? 0)
        }
    }
}
