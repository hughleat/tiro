struct SnippetEditState {
    private(set) var dirtyIDs: Set<String> = []
    private(set) var failedIDs: Set<String> = []
    private var revisions: [String: Int] = [:]
    private var queuedRevisions: [String: Int] = [:]

    var hasDirtyEdits: Bool { !dirtyIDs.isEmpty }
    var hasFailures: Bool { !failedIDs.isEmpty }

    mutating func markDirty(_ id: String) {
        dirtyIDs.insert(id)
        revisions[id, default: 0] += 1
    }

    mutating func revisionToQueue(for id: String) -> Int? {
        guard dirtyIDs.contains(id) else { return nil }
        let revision = revisions[id, default: 0]
        guard queuedRevisions[id] != revision else { return nil }
        queuedRevisions[id] = revision
        return revision
    }

    mutating func saveSucceeded(id: String, revision: Int) -> Bool {
        guard revisions[id] == revision else {
            clearQueuedRevision(id: id, revision: revision)
            return false
        }
        dirtyIDs.remove(id)
        failedIDs.remove(id)
        queuedRevisions.removeValue(forKey: id)
        return true
    }

    mutating func saveFailed(id: String, revision: Int) {
        clearQueuedRevision(id: id, revision: revision)
        failedIDs.insert(id)
    }

    mutating func remove(_ id: String) {
        dirtyIDs.remove(id)
        failedIDs.remove(id)
        revisions.removeValue(forKey: id)
        queuedRevisions.removeValue(forKey: id)
    }

    private mutating func clearQueuedRevision(id: String, revision: Int) {
        if queuedRevisions[id] == revision {
            queuedRevisions.removeValue(forKey: id)
        }
    }
}
