import AppKit
import Testing
@testable import Tiro

@Suite
struct SettingsConstructionTests {
    @Test @MainActor
    func settingsWindowCanBeConstructedDuringLaunch() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(service: TiroService())

        #expect(controller.window != nil)
    }
}
