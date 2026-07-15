enum ModifierEventState {
    static func isDown(
        familyFlagIsDown: Bool,
        physicalKeyIsDown: Bool,
        wasDown: Bool
    ) -> Bool {
        wasDown
            ? familyFlagIsDown && physicalKeyIsDown
            : familyFlagIsDown || physicalKeyIsDown
    }

    static func canceledGestureEnded(
        familyFlagIsDown: Bool,
        changedKeyIsSameFamily: Bool
    ) -> Bool {
        changedKeyIsSameFamily && !familyFlagIsDown
    }

    static func shouldRemainBlocked(
        familyFlagIsDown: Bool,
        physicalKeyIsDown: Bool,
        changedKeyIsConfigured: Bool
    ) -> Bool {
        familyFlagIsDown && (!changedKeyIsConfigured || physicalKeyIsDown)
    }
}
