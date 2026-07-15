@main
struct ModifierEventStateTests {
    static func main() {
        let commandFamily: UInt64 = 0x00100000
        let leftCommand: UInt64 = 0x00000008
        let rightCommand: UInt64 = 0x00000010
        assert(ModifierEventState.configuredModifierIsDown(
            flags: commandFamily | rightCommand,
            deviceMask: rightCommand
        ))
        assert(!ModifierEventState.configuredModifierIsDown(
            flags: commandFamily | leftCommand,
            deviceMask: rightCommand
        ))
        assert(!ModifierEventState.configuredModifierIsDown(
            flags: 0,
            deviceMask: rightCommand
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

        print("Modifier event state assertions passed")
    }
}
