import Foundation
import Testing
@testable import Tiro

struct ModelDownloadStateTests {
    @Test
    func reservesWorkingSpaceAndTwoGigabytesFree() {
        let space = ModelDownloadSpace(
            downloadBytes: 500_000_000,
            availableBytes: 3_000_000_000
        )

        #expect(space.requiredBytes == 2_756_000_000)
        #expect(space.hasEnoughSpace)
    }

    @Test
    func rejectsDownloadThatWouldConsumeSafetyReserve() {
        let space = ModelDownloadSpace(
            downloadBytes: 1_000_000_000,
            availableBytes: 3_000_000_000
        )

        #expect(space.requiredBytes == 3_256_000_000)
        #expect(!space.hasEnoughSpace)
    }

    @Test
    func unknownCapacityDoesNotBlockDownload() {
        let space = ModelDownloadSpace(
            downloadBytes: 500_000_000,
            availableBytes: nil
        )

        #expect(space.hasEnoughSpace)
    }

    @Test @MainActor
    func serviceReportsThatLowSpaceDownloadDidNotStart() {
        let service = TiroService(availableModelCapacity: { 500_000_000 })

        let started = service.startDownload(
            key: DictationModel.coreMLCompactKey
        )

        #expect(!started)
        #expect(
            service.modelOperationError(
                for: DictationModel.coreMLCompactKey
            ) == nil
        )
    }
}
