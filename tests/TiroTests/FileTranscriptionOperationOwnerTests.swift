import Testing
@testable import Tiro

struct FileTranscriptionOperationOwnerTests {
    @Test
    func staleOperationCannotFinishReplacement() {
        var owner = FileTranscriptionOperationOwner()
        let first = owner.begin()

        let cancelledFirst = owner.cancel()
        let second = owner.begin()
        let finishedFirst = owner.finish(first)
        let ownsSecond = owner.owns(second)
        let finishedSecond = owner.finish(second)
        let cancelledFinishedOperation = owner.cancel()

        #expect(cancelledFirst)
        #expect(!finishedFirst)
        #expect(ownsSecond)
        #expect(finishedSecond)
        #expect(!cancelledFinishedOperation)
    }
}
