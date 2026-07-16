import AppKit
import Testing
@testable import Tiro

@Suite
struct SettingsConstructionTests {
    @Test @MainActor
    func settingsWindowCanBeConstructedDuringLaunch() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(workerClient: WorkerClient())

        #expect(controller.window != nil)
    }
}
