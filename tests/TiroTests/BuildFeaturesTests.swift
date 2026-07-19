import Testing
@testable import Tiro

struct BuildFeaturesTests {
    @Test
    func sponsorshipMatchesCompilerConfiguration() {
#if TIRO_SPONSORSHIP_ENABLED
        #expect(BuildFeatures.sponsorshipEnabled)
        #expect(BuildFeatures.sponsorshipMenuTitle != nil)
        #expect(BuildFeatures.sponsorshipButtonTitle != nil)
#else
        #expect(!BuildFeatures.sponsorshipEnabled)
        #expect(BuildFeatures.sponsorshipMenuTitle == nil)
        #expect(BuildFeatures.sponsorshipButtonTitle == nil)
#endif
    }
}
