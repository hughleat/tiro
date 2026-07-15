import AppKit
import ApplicationServices

final class HotkeyManager {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Bool)?
    var onHoldEnd: (() -> Void)?
    var onHoldCancel: (() -> Void)?
    var onEscape: (() -> Void)?
    var shouldHandleEscape: (() -> Bool)?

    private(set) var shortcut: DictationShortcut

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcutIsDown = false
    private var blockedModifierUntilRelease: DictationShortcut.ModifierKey?
    private var suppressEscapeKeyUp = false
    private var modifierGestureCanceled = false
    private var blockedOrdinaryKeyUntilRelease: UInt16?
    private var drainedKeyCodes = Set<UInt16>()
    private var holdTriggered = false
    private var holdThresholdReached = false
    private var holdWorkItem: DispatchWorkItem?
    private var releasedShortcutMismatchCount = 0
    private let escapeKeyCode: Int64 = 53

    init(shortcut: DictationShortcut = .load()) {
        self.shortcut = shortcut
    }

    func updateShortcut(_ shortcut: DictationShortcut) throws {
        try shortcut.validate()
        cancelCurrentGesture()
        resetShortcutState()
        self.shortcut = shortcut
        blockHeldModifierIfNeeded()
    }

    func suppressUntilRelease(_ keyCodes: Set<UInt16>) {
        drainedKeyCodes.formUnion(keyCodes)
    }

    func start() throws {
        guard eventTap == nil else { return }
        drainedKeyCodes = drainedKeyCodes.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
        if case let .ordinary(keyCode, _) = shortcut.key,
           !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) {
            blockedOrdinaryKeyUntilRelease = nil
        }
        blockHeldModifierIfNeeded()
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
            NSLog("Reinstalled the global shortcut event tap.")
            return
        }

        if !CGEvent.tapIsEnabled(tap: eventTap) {
            resetAfterInterruption()
            CGEvent.tapEnable(tap: eventTap, enable: true)
            NSLog("Re-enabled the global shortcut event tap.")
        }
        repairMissedShortcutRelease()
    }

    func stop() {
        cancelCurrentGesture()
        resetShortcutState()
        suppressEscapeKeyUp = false
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetAfterInterruption()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            NSLog("Global shortcut event tap was disabled and re-enabled.")
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if let physicalKeyCode = UInt16(exactly: keyCode), drainedKeyCodes.contains(physicalKeyCode) {
            let isReleased = type == .keyUp
                || (type == .flagsChanged
                    && !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(physicalKeyCode)))
            if isReleased { drainedKeyCodes.remove(physicalKeyCode) }
            return nil
        }
        if keyCode == escapeKeyCode {
            if type == .keyDown {
                if suppressEscapeKeyUp { return nil }
                if shouldHandleEscape?() == true {
                    suppressEscapeKeyUp = true
                    cancelCurrentGesture()
                    DispatchQueue.main.async { [weak self] in self?.onEscape?() }
                    return nil
                }
            }
            if type == .keyUp, suppressEscapeKeyUp {
                suppressEscapeKeyUp = false
                return nil
            }
        }

        switch shortcut.key {
        case let .modifier(modifier):
            if blockedModifierUntilRelease == modifier {
                if type == .flagsChanged,
                   let physicalKeyCode = UInt16(exactly: keyCode),
                   let changedModifier = DictationShortcut.ModifierKey(keyCode: physicalKeyCode),
                   changedModifier.eventFlag == modifier.eventFlag,
                   !Self.isDown(modifier, in: event.flags) {
                    blockedModifierUntilRelease = nil
                }
                return Unmanaged.passUnretained(event)
            }
            if type == .flagsChanged,
               modifierGestureCanceled,
               keyCode != Int64(modifier.keyCode),
               let physicalKeyCode = UInt16(exactly: keyCode),
               let changedModifier = DictationShortcut.ModifierKey(keyCode: physicalKeyCode),
               ModifierEventState.canceledGestureEnded(
                   familyFlagIsDown: event.flags.contains(modifier.eventFlag),
                   changedKeyIsSameFamily: changedModifier.eventFlag == modifier.eventFlag
               ) {
                modifierGestureCanceled = false
            }
            if type == .flagsChanged,
               shortcutIsDown,
               keyCode != Int64(modifier.keyCode),
               let physicalKeyCode = UInt16(exactly: keyCode),
               DictationShortcut.ModifierKey(keyCode: physicalKeyCode) != nil {
                cancelCurrentGesture()
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown, shortcutIsDown {
                cancelCurrentGesture()
                return Unmanaged.passUnretained(event)
            }
            guard type == .flagsChanged, keyCode == Int64(modifier.keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            let isDown = Self.isDown(modifier, in: event.flags)
            if isDown {
                if Self.otherModifierIsDown(excluding: modifier) {
                    modifierGestureCanceled = true
                    return Unmanaged.passUnretained(event)
                }
                modifierGestureCanceled = false
                transitionShortcut(isDown: true)
            } else if modifierGestureCanceled {
                modifierGestureCanceled = false
            } else {
                transitionShortcut(isDown: false)
            }
            return Unmanaged.passUnretained(event)

        case let .ordinary(shortcutKeyCode, _):
            guard keyCode == Int64(shortcutKeyCode) else { return Unmanaged.passUnretained(event) }
            if blockedOrdinaryKeyUntilRelease == shortcutKeyCode {
                if type == .keyUp { blockedOrdinaryKeyUntilRelease = nil }
                return nil
            }
            if type == .keyDown {
                if shortcutIsDown { return nil }
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return Unmanaged.passUnretained(event)
                }
                let modifiers = DictationShortcut.Modifiers(eventFlags: event.flags)
                guard modifiers == shortcut.modifiers else { return Unmanaged.passUnretained(event) }
                transitionShortcut(isDown: true)
                return nil
            }
            if type == .keyUp, shortcutIsDown {
                transitionShortcut(isDown: false)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private func transitionShortcut(isDown: Bool) {
        if isDown, !shortcutIsDown {
            shortcutIsDown = true
            holdTriggered = false
            holdThresholdReached = false
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.shortcutIsDown else { return }
                self.holdThresholdReached = true
                self.holdTriggered = self.onHoldStart?() == true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        } else if !isDown, shortcutIsDown {
            shortcutIsDown = false
            holdWorkItem?.cancel()
            holdWorkItem = nil
            let wasHoldTriggered = holdTriggered
            let thresholdWasReached = holdThresholdReached
            holdTriggered = false
            holdThresholdReached = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if wasHoldTriggered { self.onHoldEnd?() }
                else if !thresholdWasReached { self.onTap?() }
            }
        }
    }

    private func resetShortcutState() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        shortcutIsDown = false
        holdTriggered = false
        holdThresholdReached = false
        modifierGestureCanceled = false
    }

    private func resetAfterInterruption() {
        cancelCurrentGesture()
        resetShortcutState()
        releasedShortcutMismatchCount = 0
        blockHeldModifierIfNeeded()
    }

    private func repairMissedShortcutRelease() {
        let keyCode: UInt16
        let hasStaleState: Bool
        switch shortcut.key {
        case let .modifier(modifier):
            keyCode = modifier.keyCode
            hasStaleState = blockedModifierUntilRelease == modifier
                || shortcutIsDown
                || modifierGestureCanceled
        case let .ordinary(shortcutKeyCode, _):
            keyCode = shortcutKeyCode
            hasStaleState = blockedOrdinaryKeyUntilRelease == shortcutKeyCode
                || shortcutIsDown
        }

        let shortcutIsPhysicallyDown: Bool
        switch shortcut.key {
        case let .modifier(modifier):
            shortcutIsPhysicallyDown = Self.isDown(
                modifier,
                in: CGEventSource.flagsState(.combinedSessionState)
            )
        case .ordinary:
            shortcutIsPhysicallyDown = CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(keyCode)
            )
        }
        guard hasStaleState, !shortcutIsPhysicallyDown else {
            releasedShortcutMismatchCount = 0
            return
        }
        releasedShortcutMismatchCount += 1
        guard releasedShortcutMismatchCount >= 2 else { return }

        if shortcutIsDown {
            transitionShortcut(isDown: false)
        }
        modifierGestureCanceled = false
        blockedModifierUntilRelease = nil
        blockedOrdinaryKeyUntilRelease = nil
        releasedShortcutMismatchCount = 0
        NSLog("Recovered the global shortcut after a missed key release.")
    }

    private func blockHeldModifierIfNeeded() {
        guard case let .modifier(modifier) = shortcut.key,
              Self.isDown(modifier, in: CGEventSource.flagsState(.combinedSessionState)) else {
            blockedModifierUntilRelease = nil
            return
        }
        blockedModifierUntilRelease = modifier
    }

    private func cancelCurrentGesture() {
        guard shortcutIsDown else { return }
        switch shortcut.key {
        case .modifier:
            modifierGestureCanceled = true
        case let .ordinary(keyCode, _):
            blockedOrdinaryKeyUntilRelease = keyCode
        }
        cancelActiveGesture()
        shortcutIsDown = false
    }

    private func cancelActiveGesture() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if holdTriggered { onHoldCancel?() }
        holdTriggered = false
        holdThresholdReached = false
    }

    private static func otherModifierIsDown(excluding configured: DictationShortcut.ModifierKey) -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return DictationShortcut.ModifierKey.allCases.contains { modifier in
            modifier != configured
                && isDown(modifier, in: flags)
        }
    }

    private static func isDown(
        _ modifier: DictationShortcut.ModifierKey,
        in flags: CGEventFlags
    ) -> Bool {
        ModifierEventState.configuredModifierIsDown(
            flags: flags.rawValue,
            deviceMask: modifier.deviceFlag.rawValue
        )
    }
}

enum HotkeyError: LocalizedError {
    case accessibilityRequired

    var errorDescription: String? {
        "Accessibility permission is required for global dictation keys."
    }
}
