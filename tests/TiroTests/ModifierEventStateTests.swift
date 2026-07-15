@main
struct ModifierEventStateTests {
    static func main() {
        assert(ModifierEventState.isDown(
            familyFlagIsDown: true,
            physicalKeyIsDown: false,
            wasDown: false
        ))
        assert(ModifierEventState.isDown(
            familyFlagIsDown: false,
            physicalKeyIsDown: true,
            wasDown: false
        ))
        assert(!ModifierEventState.isDown(
            familyFlagIsDown: false,
            physicalKeyIsDown: true,
            wasDown: true
        ))
        let canceledGestureWaitingForRelease = true
        assert(!ModifierEventState.isDown(
            familyFlagIsDown: true,
            physicalKeyIsDown: false,
            wasDown: canceledGestureWaitingForRelease
        ))
        assert(ModifierEventState.isDown(
            familyFlagIsDown: true,
            physicalKeyIsDown: true,
            wasDown: true
        ))
        assert(ModifierEventState.canceledGestureEnded(
            familyFlagIsDown: false,
            changedKeyIsSameFamily: true
        ))
        assert(!ModifierEventState.canceledGestureEnded(
            familyFlagIsDown: true,
            changedKeyIsSameFamily: true
        ))
        assert(!ModifierEventState.canceledGestureEnded(
            familyFlagIsDown: false,
            changedKeyIsSameFamily: false
        ))

        var initiallyHeldModifierIsBlocked = true
        initiallyHeldModifierIsBlocked = initiallyHeldModifierIsBlocked
            && ModifierEventState.shouldRemainBlocked(
                familyFlagIsDown: true,
                physicalKeyIsDown: true,
                changedKeyIsConfigured: true
            )
        assert(initiallyHeldModifierIsBlocked)
        initiallyHeldModifierIsBlocked = initiallyHeldModifierIsBlocked
            && ModifierEventState.shouldRemainBlocked(
                familyFlagIsDown: false,
                physicalKeyIsDown: true,
                changedKeyIsConfigured: true
            )
        assert(!initiallyHeldModifierIsBlocked)

        var overlappingModifierIsBlocked = true
        overlappingModifierIsBlocked = overlappingModifierIsBlocked
            && ModifierEventState.shouldRemainBlocked(
                familyFlagIsDown: true,
                physicalKeyIsDown: true,
                changedKeyIsConfigured: false
            )
        overlappingModifierIsBlocked = overlappingModifierIsBlocked
            && ModifierEventState.shouldRemainBlocked(
                familyFlagIsDown: true,
                physicalKeyIsDown: false,
                changedKeyIsConfigured: false
            )
        assert(overlappingModifierIsBlocked)
        overlappingModifierIsBlocked = overlappingModifierIsBlocked
            && ModifierEventState.shouldRemainBlocked(
                familyFlagIsDown: false,
                physicalKeyIsDown: false,
                changedKeyIsConfigured: false
            )
        assert(!overlappingModifierIsBlocked)
        print("Modifier event state assertions passed")
    }
}
