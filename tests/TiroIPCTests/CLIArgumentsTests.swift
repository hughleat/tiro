import Foundation
import Testing
@testable import TiroCLI
import TiroIPC

struct CLIArgumentsTests {
    @Test
    func parsesTranscribeOptionsAndNormalizesRelativePath() throws {
        let invocation = try CLIArguments.parse(
            [
                "transcribe", "audio/meeting.m4a", "--model", "coreml-compact",
                "--diarize", "--copy", "--no-history", "--json",
            ],
            currentDirectory: URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        )

        #expect(invocation == .transcribe(
            path: "/tmp/work/audio/meeting.m4a",
            model: "coreml-compact",
            copy: true,
            saveHistory: false,
            diarize: true,
            format: .json
        ))
    }

    @Test
    func parsesDiarizeAlias() throws {
        #expect(try CLIArguments.parse(
            ["diarize", "meeting.wav", "--json"],
            currentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        ) == .transcribe(
            path: "/tmp/meeting.wav",
            model: nil,
            copy: false,
            saveHistory: true,
            diarize: true,
            format: .json
        ))
    }

    @Test
    func parsesStatusAndRejectsAmbiguousInput() throws {
        #expect(try CLIArguments.parse(["status", "--json"]) == .status(format: .json))
        #expect(try CLIArguments.parse(["models", "--json"]) == .models(format: .json))
        #expect(throws: CLIArgumentError.self) {
            try CLIArguments.parse(["transcribe", "one.wav", "two.wav"])
        }
        #expect(throws: CLIArgumentError.self) {
            try CLIArguments.parse(["transcribe", "one.wav", "--model"])
        }
    }

    @Test
    func parsesRecordingLifecycle() throws {
        let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        #expect(try CLIArguments.parse([
            "record", "start", "--model", "coreml-compact", "--no-history"
        ]) == .recordStart(
            model: "coreml-compact",
            saveHistory: false,
            format: .text
        ))
        #expect(try CLIArguments.parse([
            "record", "stop", session, "--copy", "--json"
        ]) == .recordStop(session: session, copy: true, format: .json))
        #expect(try CLIArguments.parse([
            "record", "cancel", session
        ]) == .recordCancel(session: session, format: .text))
    }

    @Test
    func outputKeepsTextAndJSONMachineReadable() throws {
        let request = TiroCommandRequest.status()
        let message = TiroCommandMessage.success(
            id: request.id,
            result: TiroCommandResult(
                kind: "transcript",
                text: "Hello world",
                segments: [
                    TiroCommandSegment(
                        text: "Hello world",
                        startTime: 0.25,
                        endTime: 1.5,
                        speakerID: "speaker-1"
                    ),
                ]
            )
        )
        #expect(
            String(decoding: try CLIOutput.success(message, format: .text), as: UTF8.self)
                == "Hello world\n"
        )
        let success = try #require(
            JSONSerialization.jsonObject(
                with: try CLIOutput.success(message, format: .json)
            ) as? [String: Any]
        )
        let result = try #require(success["result"] as? [String: Any])
        let segments = try #require(result["segments"] as? [[String: Any]])
        #expect(segments.first?["speaker_id"] as? String == "speaker-1")
        #expect(segments.first?["start"] as? Double == 0.25)

        let failure = try CLIOutput.failure(
            code: "busy",
            message: "Tiro is busy.",
            format: .json
        )
        #expect(failure.standardError.isEmpty)
        let object = try #require(
            JSONSerialization.jsonObject(with: failure.standardOutput) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["schema"] as? Int == 1)
    }
}
