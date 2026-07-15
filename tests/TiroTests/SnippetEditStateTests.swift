@main
struct SnippetEditStateTests {
    static func main() {
        staleSaveCannotClearNewerEdit()
        failureRemainsVisibleUntilThatSnippetSucceeds()
        removeClearsPendingAndFailedState()
        print("Snippet edit state assertions passed")
    }

    static func staleSaveCannotClearNewerEdit() {
        var state = SnippetEditState()
        state.markDirty("one")
        let firstRevision = state.revisionToQueue(for: "one")!
        state.markDirty("one")
        let secondRevision = state.revisionToQueue(for: "one")!

        assert(!state.saveSucceeded(id: "one", revision: firstRevision))
        assert(state.hasDirtyEdits)
        assert(state.saveSucceeded(id: "one", revision: secondRevision))
        assert(!state.hasDirtyEdits)
    }

    static func failureRemainsVisibleUntilThatSnippetSucceeds() {
        var state = SnippetEditState()
        state.markDirty("one")
        let failedRevision = state.revisionToQueue(for: "one")!
        state.saveFailed(id: "one", revision: failedRevision)

        state.markDirty("two")
        let successfulRevision = state.revisionToQueue(for: "two")!
        assert(state.saveSucceeded(id: "two", revision: successfulRevision))
        assert(state.hasFailures)

        let retryRevision = state.revisionToQueue(for: "one")!
        assert(state.saveSucceeded(id: "one", revision: retryRevision))
        assert(!state.hasFailures)
    }

    static func removeClearsPendingAndFailedState() {
        var state = SnippetEditState()
        state.markDirty("one")
        let revision = state.revisionToQueue(for: "one")!
        state.saveFailed(id: "one", revision: revision)

        state.remove("one")
        assert(!state.hasDirtyEdits)
        assert(!state.hasFailures)
        assert(state.revisionToQueue(for: "one") == nil)
    }
}
