import Foundation
import Testing
@testable import TiroIPC

struct CommandProtocolTests {
    @Test
    func requestUsesStableWireKeys() throws {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let request = TiroCommandRequest.transcribe(
            path: "/tmp/meeting.m4a",
            model: "coreml-compact",
            copy: true,
            saveHistory: false,
            diarize: true,
            id: id
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        #expect(object["v"] as? Int == 1)
        #expect(object["id"] as? String == id.uuidString.lowercased())
        #expect(object["command"] as? String == "transcribe")
        let arguments = try #require(object["arguments"] as? [String: Any])
        #expect(arguments["path"] as? String == "/tmp/meeting.m4a")
        #expect(arguments["save_history"] as? Bool == false)
        #expect(arguments["diarize"] as? Bool == true)
    }

    @Test
    func resultUsesFoundationOnlyStructuredSegments() throws {
        let result = TiroCommandResult(
            kind: "transcript",
            text: "Hello.",
            segments: [
                TiroCommandSegment(
                    text: "Hello.",
                    startTime: 1.25,
                    endTime: 2.5,
                    speakerID: "speaker-1"
                ),
            ]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
                as? [String: Any]
        )
        let segments = try #require(object["segments"] as? [[String: Any]])
        #expect(segments.first?["text"] as? String == "Hello.")
        #expect(segments.first?["start"] as? Double == 1.25)
        #expect(segments.first?["end"] as? Double == 2.5)
        #expect(segments.first?["speaker_id"] as? String == "speaker-1")
    }

    @Test
    func validationRejectsDiarizeOnRecordingCommands() {
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordStart,
                arguments: TiroCommandArguments(diarize: true)
            ).validated()
        }
    }

    @Test
    func validationRejectsWrongResponseAndProgress() throws {
        let request = TiroCommandRequest.status()
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.success(
                id: UUID().uuidString,
                result: TiroCommandResult(kind: "status")
            ).validated(for: request)
        }
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandMessage.event(
                id: request.id,
                name: "working",
                fraction: 1.1
            ).validated(for: request)
        }
    }

    @Test
    func recordingRequestsRequireAValidSession() throws {
        let session = UUID()
        #expect(try TiroCommandRequest.recordStart(
            model: nil,
            saveHistory: true
        ).validated().command == .recordStart)
        #expect(try TiroCommandRequest.recordStop(
            session: session.uuidString,
            copy: true
        ).validated().arguments?.session == session.uuidString)
        #expect(throws: TiroProtocolError.self) {
            try TiroCommandRequest(
                command: .recordCancel,
                arguments: TiroCommandArguments(session: "not-a-session")
            ).validated()
        }
    }

    @Test
    func socketOverrideAndFallbackAreBounded() throws {
        let override = TiroCommandSocketPath.defaultURL(
            environment: ["TIRO_COMMAND_SOCKET": "/tmp/Tiro/custom-tiro.sock"]
        )
        #expect(override.path == "/tmp/Tiro/custom-tiro.sock")
        try TiroCommandSocketPath.validate(override)

        let unsafeOverride = TiroCommandSocketPath.defaultURL(
            environment: ["TIRO_COMMAND_SOCKET": "/tmp/custom-tiro.sock"]
        )
        #expect(throws: TiroSocketError.unsafeSocketDirectory) {
            try TiroCommandSocketPath.validate(unsafeOverride)
        }

        let excessive = URL(fileURLWithPath: "/" + String(repeating: "x", count: 200))
        #expect(throws: TiroSocketError.self) {
            try TiroCommandSocketPath.validate(excessive)
        }
    }
}
