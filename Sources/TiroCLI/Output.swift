import Foundation
import TiroIPC

enum CLIOutput {
    static func success(
        _ message: TiroCommandMessage,
        format: CLIOutputFormat
    ) throws -> Data {
        guard let result = message.result else {
            throw CLIExecutionError.malformedResult
        }
        switch format {
        case .json:
            return try jsonData(JSONEnvelope(ok: true, result: result, error: nil))
        case .text:
            let value: String
            if result.kind == "transcript" {
                value = result.text ?? ""
            } else if result.kind == "status" {
                value = result.state ?? "unknown"
            } else if result.kind == "models" {
                value = (result.models ?? []).map {
                    "\($0.key)\t\($0.installed ? "installed" : "not installed")\t\($0.name)"
                }.joined(separator: "\n")
            } else if result.kind == "recording" {
                value = result.session ?? ""
            } else if result.kind == "cancelled" {
                value = "cancelled"
            } else {
                throw CLIExecutionError.malformedResult
            }
            return Data((value + "\n").utf8)
        }
    }

    static func failure(
        code: String,
        message: String,
        format: CLIOutputFormat
    ) throws -> (standardOutput: Data, standardError: Data) {
        switch format {
        case .json:
            return (
                try jsonData(JSONEnvelope(
                    ok: false,
                    result: nil,
                    error: TiroCommandFailure(code: code, message: message)
                )),
                Data()
            )
        case .text:
            return (Data(), Data(("tiro: \(message)\n").utf8))
        }
    }

    private static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

private struct JSONEnvelope: Encodable {
    let schema = 1
    let ok: Bool
    let result: TiroCommandResult?
    let error: TiroCommandFailure?
}
