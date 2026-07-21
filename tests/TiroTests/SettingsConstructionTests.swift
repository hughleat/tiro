import AppKit
import Foundation
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

    @Test
    func historyActionLabelsIncludeConciseTranscriptContext() {
        #expect(
            HistoryAccessibility.actionLabel(
                "Copy transcript",
                transcript: "  A   short\ntranscript  "
            ) == "Copy transcript, A short transcript"
        )
        let long = String(repeating: "word ", count: 20)
        let label = HistoryAccessibility.actionLabel("Play recording", transcript: long)
        #expect(label.hasPrefix("Play recording, "))
        #expect(label.hasSuffix("..."))
        #expect(label.count == "Play recording, ".count + 60)
        #expect(
            HistoryAccessibility.actionLabel("Delete transcription", transcript: "")
                == "Delete transcription, Untitled transcription"
        )
    }

    @Test @MainActor
    func settingsSidebarIconsAreDecorative() {
        let imageView = NSImageView()
        SettingsNavigationController.configureSidebarIcon(imageView, symbolName: "gearshape")

        #expect(imageView.isAccessibilityElement() == false)
    }

    @Test
    func commandLineInstallerRejectsRegularFileAndUnrelatedLink() throws {
        let fixture = try CommandLineInstallerFixture()
        defer { fixture.remove() }

        try Data("occupied".utf8).write(to: fixture.linkURL)
        #expect(fixture.installer.state == .conflict)
        #expect(throws: CommandLineToolError.self) { try fixture.installer.install() }
        #expect(throws: CommandLineToolError.self) { try fixture.installer.uninstall() }

        try FileManager.default.removeItem(at: fixture.linkURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(fixture.installer.state == .conflict)
    }

    @Test
    func commandLineInstallerRecognizesOnlyValidatedTiroLinks() throws {
        let fixture = try CommandLineInstallerFixture()
        defer { fixture.remove() }

        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: fixture.helperURL
        )
        #expect(fixture.installer.state == .installed)

        try FileManager.default.removeItem(at: fixture.linkURL)
        let oldHelper = try fixture.makeApp(in: "old", bundleIdentifier: "local.tiro.dictation")
        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: oldHelper
        )
        #expect(fixture.installer.state == .needsRepair)

        try FileManager.default.removeItem(at: fixture.linkURL)
        let unrelatedHelper = try fixture.makeApp(in: "other", bundleIdentifier: "example.other")
        try FileManager.default.createSymbolicLink(
            at: fixture.linkURL,
            withDestinationURL: unrelatedHelper
        )
        #expect(fixture.installer.state == .conflict)
    }
}

private struct CommandLineInstallerFixture {
    let root: URL
    let bundleURL: URL
    let helperURL: URL
    let linkURL: URL

    var installer: CommandLineToolInstaller {
        CommandLineToolInstaller(bundleURL: bundleURL, linkURL: linkURL)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiro-installer-tests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = root.appendingPathComponent("Tiro.app", isDirectory: true)
        linkURL = root.appendingPathComponent("bin/tiro")
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        helperURL = try Self.makeApp(
            at: bundleURL,
            bundleIdentifier: "local.tiro.dictation"
        )
    }

    func makeApp(in directory: String, bundleIdentifier: String) throws -> URL {
        try Self.makeApp(
            at: root
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("Tiro.app", isDirectory: true),
            bundleIdentifier: bundleIdentifier
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeApp(at appURL: URL, bundleIdentifier: String) throws -> URL {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helper = contents
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("tiro")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return helper
    }
}
