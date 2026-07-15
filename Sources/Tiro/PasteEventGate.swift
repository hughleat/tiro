@MainActor
final class PasteEventGate {
    static let shared = PasteEventGate()
    nonisolated static let marker: Int64 = 0x5449524F

    private var destination: DestinationSession?
    private var keyDownWasAllowed = false
    private var result: Bool?

    private init() {}

    func arm(for destination: DestinationSession) {
        self.destination = destination
        keyDownWasAllowed = false
        result = nil
    }

    func shouldPass(keyDown: Bool) -> Bool {
        if keyDown {
            keyDownWasAllowed = destination?.isCurrentPasteTargetAtDispatch == true
            if !keyDownWasAllowed { result = false }
            return keyDownWasAllowed
        }

        let shouldPass = keyDownWasAllowed
        destination = nil
        keyDownWasAllowed = false
        result = shouldPass
        return shouldPass
    }

    func consumeResult() -> Bool? {
        defer { result = nil }
        return result
    }
}
