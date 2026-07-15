import AppKit
import ApplicationServices

final class HotkeyManager {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onEscape: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightCommandDown = false
    private var holdTriggered = false
    private var holdWorkItem: DispatchWorkItem?
    private let rightCommandKeyCode: Int64 = 54
    private let escapeKeyCode: Int64 = 53

    func start() throws {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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

    func stop() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        rightCommandDown = false
        holdTriggered = false
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, keyCode == escapeKeyCode {
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged, keyCode == rightCommandKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = event.flags.contains(.maskCommand)
        if isDown, !rightCommandDown {
            rightCommandDown = true
            holdTriggered = false
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.rightCommandDown else { return }
                self.holdTriggered = true
                self.onHoldStart?()
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        } else if !isDown, rightCommandDown {
            rightCommandDown = false
            holdWorkItem?.cancel()
            holdWorkItem = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.holdTriggered { self.onHoldEnd?() }
                else { self.onTap?() }
            }
        }
        return nil
    }
}

enum HotkeyError: LocalizedError {
    case accessibilityRequired

    var errorDescription: String? {
        "Accessibility permission is required for global dictation keys."
    }
}
