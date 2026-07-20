import Testing
@testable import Tiro

@Suite("Transcription job gate")
struct TranscriptionJobGateTests {
    @Test
    func releasesWaitersInArrivalOrder() async throws {
        let gate = TranscriptionJobGate()
        try await gate.acquire()

        let first = Task {
            try await gate.acquire()
            await gate.release()
            return 1
        }
        let second = Task {
            try await gate.acquire()
            await gate.release()
            return 2
        }

        await Task.yield()
        await gate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
    }

    @Test
    func cancelledWaiterDoesNotBlockFollowingWork() async throws {
        let gate = TranscriptionJobGate()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await gate.release()
        try await gate.acquire()
        await gate.release()
    }
}
