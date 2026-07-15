import AppKit
import ApplicationServices

struct ApplicationIdentity {
    let bundleIdentifier: String?
    let applicationName: String?
}

@MainActor
struct DestinationSession {
    struct PasteObservation {
        let expectedValue: String?

        var canConfirmConsumption: Bool { expectedValue != nil }
    }

    private let application: NSRunningApplication
    private let applicationElement: AXUIElement
    private let windowElement: AXUIElement
    private let focusedElement: AXUIElement

    var processIdentifier: pid_t { application.processIdentifier }
    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }
    var isCurrentPasteTargetAtDispatch: Bool {
        guard isFrontmost,
              let currentElement = currentFocusedElement(
                  for: applicationElement,
                  processIdentifier: processIdentifier
              ),
              let currentWindow = currentFocusedWindow(
                  for: applicationElement,
                  focusedElement: currentElement
              ) else { return false }
        return CFEqual(currentWindow, windowElement)
            && CFEqual(currentElement, focusedElement)
    }
    init(
        application: NSRunningApplication,
        applicationElement: AXUIElement,
        windowElement: AXUIElement,
        focusedElement: AXUIElement
    ) {
        self.application = application
        self.applicationElement = applicationElement
        self.windowElement = windowElement
        self.focusedElement = focusedElement
    }

    var isAvailable: Bool {
        guard !application.isTerminated,
              NSRunningApplication(processIdentifier: processIdentifier) != nil,
              belongsToApplication(windowElement),
              belongsToApplication(focusedElement) else { return false }

        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &role
        ) == .success
    }

    var isSecure: Bool {
        var element: AXUIElement? = focusedElement

        for _ in 0..<12 {
            guard let current = element else { return false }
            if stringAttribute(kAXSubroleAttribute as CFString, of: current) == kAXSecureTextFieldSubrole
                || boolAttribute(NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString, of: current) {
                return true
            }
            element = elementAttribute(kAXParentAttribute as CFString, of: current)
        }

        return false
    }

    func restore() async -> Bool {
        guard isAvailable else { return false }
        if isFrontmost, isFocused {
            return true
        }
        guard application.activate(options: []) else { return false }

        for _ in 0..<15 {
            guard isAvailable else { return false }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostPID == processIdentifier {
                if isFocused { return true }
                _ = AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFocusedWindowAttribute as CFString,
                    windowElement
                )
                _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
                let focusedViaApplication = AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFocusedUIElementAttribute as CFString,
                    focusedElement
                )
                let focusedDirectly = AXUIElementSetAttributeValue(
                    focusedElement,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
                if (focusedViaApplication == .success || focusedDirectly == .success)
                    && isFocused {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func observePasteTarget(afterInserting text: String) -> PasteObservation {
        guard let original = stringAttribute(kAXValueAttribute as CFString, of: focusedElement),
              let range = rangeAttribute(kAXSelectedTextRangeAttribute as CFString, of: focusedElement),
              range.location >= 0,
              range.length >= 0,
              (original as NSString).length <= 250_000,
              range.location <= (original as NSString).length,
              range.length <= (original as NSString).length - range.location
        else { return PasteObservation(expectedValue: nil) }

        let expected = NSMutableString(string: original)
        expected.replaceCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
        let expectedValue = expected as String
        return PasteObservation(expectedValue: expectedValue == original ? nil : expectedValue)
    }

    func hasConsumedPaste(since observation: PasteObservation) -> Bool {
        guard let expectedValue = observation.expectedValue, isFocused else { return false }
        return stringAttribute(kAXValueAttribute as CFString, of: focusedElement) == expectedValue
    }

    var isFocused: Bool {
        guard let currentElement = currentFocusedElement(
                  for: applicationElement,
                  processIdentifier: processIdentifier
              ),
              let currentWindow = currentFocusedWindow(
                  for: applicationElement,
                  focusedElement: currentElement
              )
        else { return false }
        return CFEqual(currentWindow, windowElement) && CFEqual(currentElement, focusedElement)
    }

    private func belongsToApplication(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == processIdentifier
    }
}

@MainActor
final class DestinationTracker: NSObject {
    private var lastNonTiroApplication: NSRunningApplication?

    override init() {
        super.init()
        rememberIfEligible(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func capture() -> DestinationSession? {
        guard let application = currentApplication() else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        guard let focusedElement = currentFocusedElement(
            for: appElement,
            processIdentifier: application.processIdentifier
        ) else { return nil }
        guard let window = currentFocusedWindow(
            for: appElement,
            focusedElement: focusedElement
        )
        else { return nil }

        return DestinationSession(
            application: application,
            applicationElement: appElement,
            windowElement: window,
            focusedElement: focusedElement
        )
    }

    func captureApplicationIdentity() -> ApplicationIdentity? {
        guard let application = currentApplication() else { return nil }
        return ApplicationIdentity(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        rememberIfEligible(
            notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        )
    }

    private func rememberIfEligible(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else { return }
        lastNonTiroApplication = application
    }

    private func currentApplication() -> NSRunningApplication? {
        rememberIfEligible(NSWorkspace.shared.frontmostApplication)
        guard let application = lastNonTiroApplication,
              !application.isTerminated else { return nil }
        return application
    }
}

private func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func currentFocusedElement(
    for applicationElement: AXUIElement,
    processIdentifier: pid_t
) -> AXUIElement? {
    if let focused = elementAttribute(
        kAXFocusedUIElementAttribute as CFString,
        of: applicationElement
    ) {
        return focused
    }

    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.05)
    guard let focused = elementAttribute(
        kAXFocusedUIElementAttribute as CFString,
        of: systemWide
    ) else { return nil }
    var focusedPID: pid_t = 0
    guard AXUIElementGetPid(focused, &focusedPID) == .success,
          focusedPID == processIdentifier else { return nil }
    return focused
}

private func currentFocusedWindow(
    for applicationElement: AXUIElement,
    focusedElement: AXUIElement
) -> AXUIElement? {
    if let window = elementAttribute(
        kAXFocusedWindowAttribute as CFString,
        of: applicationElement
    ) {
        return window
    }
    AXUIElementSetMessagingTimeout(focusedElement, 0.05)
    return elementAttribute(kAXWindowAttribute as CFString, of: focusedElement)
}

private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

private func rangeAttribute(_ name: CFString, of element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
}

private func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
    return (value as? NSNumber)?.boolValue == true
}
