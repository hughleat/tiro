import ApplicationServices

@MainActor
final class PasteEventGate {
    static let shared = PasteEventGate()
    nonisolated static let marker: Int64 = 0x5449524F

    private var destination: (any PasteDestination)?
    private var keyDownWasAllowed = false
    private var result: Bool?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() throws {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let gate = Unmanaged<PasteEventGate>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                gate.handle(type: type, event: event)
            }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.accessibilityRequired
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func maintain() throws {
        guard let eventTap,
              runLoopSource != nil,
              CFMachPortIsValid(eventTap) else {
            stop()
            try start()
            NSLog("Reinstalled the auto-paste event gate.")
            return
        }
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            NSLog("Re-enabled the auto-paste event gate.")
        }
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        destination = nil
        keyDownWasAllowed = false
        result = nil
    }

    func arm(for destination: any PasteDestination) {
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) == Self.marker else {
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        return shouldPass(keyDown: type == .keyDown)
            ? Unmanaged.passUnretained(event)
            : nil
    }
}
