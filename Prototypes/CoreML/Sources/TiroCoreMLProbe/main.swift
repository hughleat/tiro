import Foundation
import TiroRecognition

@main
struct TiroCoreMLProbe {
    static func main() async {
        do {
            let options = try CoreMLProbeOptions.parse(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            guard FileManager.default.fileExists(atPath: options.audioURL.path) else {
                throw ProbeError.audioNotFound(options.audioURL)
            }

            let wallStart = ContinuousClock.now
            let engine = CoreMLParakeetEngine(modelDirectory: options.modelDirectory)
            let preparation = try await engine.prepare(
                model: .parakeetCompactCoreML,
                allowDownload: options.allowDownload
            )
            let transcript = try await engine.recognize(
                RecognitionRequest(
                    audioURL: options.audioURL,
                    model: .parakeetCompactCoreML
                )
            )
            let output = CoreMLProbeResult(
                transcript: transcript,
                modelDirectory: options.modelDirectory.path,
                installedModelBytes: DirectorySize.bytes(at: options.modelDirectory),
                downloadSeconds: preparation.downloadSeconds,
                loadSeconds: preparation.loadSeconds,
                wallSeconds: seconds(since: wallStart)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
        } catch CoreMLProbeOptionError.helpRequested {
            printUsage(to: stdout)
        } catch {
            fputs("Tiro Core ML probe: \(error.localizedDescription)\n\n", stderr)
            printUsage(to: stderr)
            exit(1)
        }
    }

    private static func seconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private static func printUsage(to stream: UnsafeMutablePointer<FILE>) {
        fputs(
            """
            Usage:
              TiroCoreMLProbe --audio FILE [--model-dir ROOT] [--download]

            The model is never downloaded unless --download is present.

            """,
            stream
        )
    }
}

private enum ProbeError: LocalizedError {
    case audioNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .audioNotFound(let url):
            return "Audio file not found: \(url.path)"
        }
    }
}
