import AppKit
import ApplicationServices

@MainActor
final class PasteCoordinator {
    enum PasteResult {
        case confirmed
        case dispatched
    }

    enum PasteError: LocalizedError {
        case unavailableDestination
        case secureDestination
        case couldNotRestoreDestination
        case couldNotSnapshotPasteboard
        case clipboardChanged
        case couldNotWritePasteboard
        case couldNotCreateKeyboardEvent
        case keyboardEventRejected
        case pasteNotConsumed

        var errorDescription: String? {
            switch self {
            case .unavailableDestination: "The original paste destination is no longer available."
            case .secureDestination: "Tiro will not paste into a secure text field."
            case .couldNotRestoreDestination: "The original paste destination could not be restored."
            case .couldNotSnapshotPasteboard: "The current clipboard contents could not be preserved."
            case .clipboardChanged: "The clipboard changed before Tiro could paste."
            case .couldNotWritePasteboard: "The transcription could not be written to the clipboard."
            case .couldNotCreateKeyboardEvent: "The paste keyboard event could not be created."
            case .keyboardEventRejected: "macOS rejected the paste keyboard event."
            case .pasteNotConsumed: "The destination did not accept the pasted text."
            }
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int

        init?(_ pasteboard: NSPasteboard) {
            changeCount = pasteboard.changeCount
            var capturedItems: [[NSPasteboard.PasteboardType: Data]] = []

            for item in pasteboard.pasteboardItems ?? [] {
                var capturedTypes: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    capturedTypes[type] = data
                }
                capturedItems.append(capturedTypes)
            }

            guard pasteboard.changeCount == changeCount else { return nil }
            items = capturedItems
        }

        func restore(to pasteboard: NSPasteboard) {
            let restoredItems = items.map { capturedTypes in
                let item = NSPasteboardItem()
                for (type, data) in capturedTypes {
                    item.setData(data, forType: type)
                }
                return item
            }

            pasteboard.clearContents()
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    private struct PendingRestoration {
        let snapshot: PasteboardSnapshot
        let injectedChangeCount: Int
        let identifier: UUID
    }

    private let pasteboard: NSPasteboard
    private var pendingRestoration: PendingRestoration?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func paste(_ text: String, to destination: DestinationSession) async throws -> PasteResult {
        pendingRestoration = nil

        guard destination.isAvailable else { throw PasteError.unavailableDestination }
        guard !destination.isSecure else { throw PasteError.secureDestination }
        guard await destination.restore() else { throw PasteError.couldNotRestoreDestination }
        guard destination.isAvailable else { throw PasteError.unavailableDestination }
        guard !destination.isSecure else { throw PasteError.secureDestination }

        guard let snapshot = PasteboardSnapshot(pasteboard) else {
            throw PasteError.couldNotSnapshotPasteboard
        }
        guard pasteboard.changeCount == snapshot.changeCount else {
            throw PasteError.clipboardChanged
        }

        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount
        guard pasteboard.setString(text, forType: .string) else {
            if pasteboard.changeCount == clearedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            throw PasteError.couldNotWritePasteboard
        }

        let injectedChangeCount = pasteboard.changeCount
        let identifier = UUID()
        pendingRestoration = PendingRestoration(
            snapshot: snapshot,
            injectedChangeCount: injectedChangeCount,
            identifier: identifier
        )

        let observation = destination.observePasteTarget(afterInserting: text)
        guard destination.isAvailable,
              destination.isFrontmost,
              destination.isFocused,
              !destination.isSecure else {
            if pasteboard.changeCount == injectedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            pendingRestoration = nil
            throw PasteError.couldNotRestoreDestination
        }
        guard let keyDown = makePasteEvent(keyDown: true),
              let keyUp = makePasteEvent(keyDown: false) else {
            pendingRestoration = nil
            throw PasteError.couldNotCreateKeyboardEvent
        }
        PasteEventGate.shared.arm(for: destination)
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        guard await pasteEventWasAccepted() else {
            pendingRestoration = nil
            throw PasteError.keyboardEventRejected
        }
        guard observation.canConfirmConsumption else {
            pendingRestoration = nil
            return .dispatched
        }
        guard await confirmConsumption(
            by: destination,
            since: observation,
            identifier: identifier
        ) else {
            throw PasteError.pasteNotConsumed
        }
        return .confirmed
    }

    private func makePasteEvent(keyDown: Bool) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)
        else { return nil }
        event.flags = .maskCommand
        event.setIntegerValueField(
            .eventSourceUserData,
            value: PasteEventGate.marker
        )
        return event
    }

    private func pasteEventWasAccepted() async -> Bool {
        for _ in 0..<20 {
            if let accepted = PasteEventGate.shared.consumeResult() {
                return accepted
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func restoreClipboardIfUnchanged(identifier: UUID) {
        guard let pendingRestoration,
              pendingRestoration.identifier == identifier else { return }

        if pasteboard.changeCount == pendingRestoration.injectedChangeCount {
            pendingRestoration.snapshot.restore(to: pasteboard)
        }
        self.pendingRestoration = nil
    }

    private func confirmConsumption(
        by destination: DestinationSession,
        since observation: DestinationSession.PasteObservation,
        identifier: UUID
    ) async -> Bool {
        var delay: UInt64 = 20_000_000
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: delay)
            guard pendingRestoration?.identifier == identifier else { return false }
            if destination.hasConsumedPaste(since: observation) {
                restoreClipboardIfUnchanged(identifier: identifier)
                return true
            }
            delay = min(delay * 2, 400_000_000)
        }
        discardPendingRestoration(identifier: identifier)
        return false
    }

    private func discardPendingRestoration(identifier: UUID) {
        guard pendingRestoration?.identifier == identifier else { return }
        pendingRestoration = nil
    }
}
