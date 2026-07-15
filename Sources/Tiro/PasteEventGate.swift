@MainActor
final class PasteEventGate {
    static let shared = PasteEventGate()
    nonisolated static let marker: Int64 = 0x5449524F

    private var destination: DestinationSession?
    private var keyDownWasAllowed = false

    private init() {}

    func arm(for destination: DestinationSession) {
        self.destination = destination
        keyDownWasAllowed = false
    }

    func shouldPass(keyDown: Bool) -> Bool {
        if keyDown {
            keyDownWasAllowed = destination?.isCurrentPasteTargetAtDispatch == true
            return keyDownWasAllowed
        }

        let shouldPass = keyDownWasAllowed
        destination = nil
        keyDownWasAllowed = false
        return shouldPass
    }
}
