import AppKit

if CommandLine.arguments.dropFirst() == ["--print-build-features"] {
    print("sponsorship=\(BuildFeatures.sponsorshipEnabled)")
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
