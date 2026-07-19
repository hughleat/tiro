import Foundation

enum BuildFeatures {
#if TIRO_SPONSORSHIP_ENABLED
    static let sponsorshipEnabled = true
    static let sponsorshipMenuTitle: String? = "Support Tiro..."
    static let sponsorshipButtonTitle: String? = "Support Tiro"
    static let sponsorsURL = URL(string: "https://github.com/sponsors/hughleat")!
#else
    static let sponsorshipEnabled = false
    static let sponsorshipMenuTitle: String? = nil
    static let sponsorshipButtonTitle: String? = nil
#endif
}
