import Testing
@testable import Tiro

struct SetupReadinessTests {
    @Test
    func setupRequiresBothPermissionsAndAnInstalledModel() {
        let ready = SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: true,
            installedModelKeys: ["compact"]
        )
        #expect(ready.canFinish)

        #expect(!SetupReadiness(
            microphoneAllowed: false,
            accessibilityAllowed: true,
            installedModelKeys: ["compact"]
        ).canFinish)
        #expect(!SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: false,
            installedModelKeys: ["compact"]
        ).canFinish)
        #expect(!SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: true,
            installedModelKeys: []
        ).canFinish)
    }

    @Test
    func modelInventoryDoesNotTreatLoadingOrFailureAsMissing() {
        #expect(ModelInventoryStatus.loading != .missing)
        #expect(ModelInventoryStatus.unavailable != .missing)
        #expect(ModelInventoryStatus.available != .missing)
        #expect(ModelInventoryStatus.missing == .missing)
        #expect(ModelInventoryStatus.loading.afterPreparationFailure == .unavailable)
        #expect(ModelInventoryStatus.available.afterPreparationFailure == .available)
    }
}
