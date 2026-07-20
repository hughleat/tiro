import Foundation
import Testing
@testable import Tiro

struct CommandLineToolInstallerTests {
    @Test
    func regularFileAndUnrelatedSymlinkAreConflicts() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link
        )

        FileManager.default.createFile(atPath: fixture.link.path, contents: Data())
        #expect(installer.state == .conflict)

        try FileManager.default.removeItem(at: fixture.link)
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.root.appendingPathComponent("someone-elses-tool")
        )
        #expect(installer.state == .conflict)
    }

    @Test
    func onlyValidatedTiroBundleSymlinksAreManaged() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link
        )

        let oldApp = try fixture.makeApp(named: "Previous/Tiro.app")
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.helper(in: oldApp)
        )
        #expect(installer.state == .needsRepair)

        try FileManager.default.removeItem(at: fixture.link)
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.helper(in: fixture.currentApp)
        )
        #expect(installer.state == .installed)
    }

    @Test
    func lookalikeBundleWithWrongIdentifierIsAConflict() throws {
        let fixture = try InstallerFixture()
        defer { fixture.remove() }
        let impostor = try fixture.makeApp(
            named: "Impostor/Tiro.app",
            bundleIdentifier: "example.not-tiro"
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.helper(in: impostor)
        )

        let installer = CommandLineToolInstaller(
            bundleURL: fixture.currentApp,
            linkURL: fixture.link
        )
        #expect(installer.state == .conflict)
    }
}

private final class InstallerFixture {
    let root: URL
    let currentApp: URL
    let link: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiro-installer-\(UUID().uuidString)", isDirectory: true)
        link = root.appendingPathComponent("bin/tiro")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        currentApp = root.appendingPathComponent("Current/Tiro.app", isDirectory: true)
        try Self.createApp(at: currentApp, bundleIdentifier: "local.tiro.dictation")
    }

    func makeApp(
        named path: String,
        bundleIdentifier: String = "local.tiro.dictation"
    ) throws -> URL {
        let app = root.appendingPathComponent(path, isDirectory: true)
        try Self.createApp(at: app, bundleIdentifier: bundleIdentifier)
        return app
    }

    func helper(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers/tiro")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func createApp(at app: URL, bundleIdentifier: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let helper = contents.appendingPathComponent("Helpers/tiro")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
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
    }
}
