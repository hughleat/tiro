import Foundation
import Testing
@testable import Tiro

struct UpdateCheckerTests {
    @Test
    func releaseVersionsOrderBetasBeforeStable() throws {
        let beta1 = try #require(ReleaseVersion("v0.1.0-beta.1"))
        let beta2 = try #require(ReleaseVersion("0.1.0-beta.2"))
        let stable = try #require(ReleaseVersion("v0.1.0"))
        #expect(beta1 < beta2)
        #expect(beta2 < stable)
        #expect(stable < ReleaseVersion("v0.2.0")!)
    }

    @Test
    func rejectsMalformedReleaseVersions() {
        #expect(ReleaseVersion("0.1") == nil)
        #expect(ReleaseVersion("v0.1.0-rc.1") == nil)
        #expect(ReleaseVersion("words") == nil)
    }

    @Test
    func selectsNewestPublishedRelease() throws {
        let data = Data("""
        [
          {"tag_name":"v0.2.0-beta.1","html_url":"https://example.com/draft","draft":true,"prerelease":true},
          {"tag_name":"v0.1.0-beta.1","html_url":"https://example.com/beta1","draft":false,"prerelease":true},
          {"tag_name":"v0.1.0-beta.2","html_url":"https://example.com/beta2","draft":false,"prerelease":true}
        ]
        """.utf8)
        let result = try UpdateChecker.result(currentTag: "v0.1.0-beta.1", data: data)
        guard case .updateAvailable(let release) = result else {
            Issue.record("Expected an available update")
            return
        }
        #expect(release.tagName == "v0.1.0-beta.2")
    }

    @Test
    func identifiesCurrentAndUntaggedBuilds() throws {
        let data = Data("""
        [{"tag_name":"v0.1.0-beta.2","html_url":"https://example.com/beta2","draft":false,"prerelease":true}]
        """.utf8)
        #expect(try UpdateChecker.result(currentTag: "v0.1.0-beta.2", data: data) == .current(
            GitHubRelease(
                tagName: "v0.1.0-beta.2",
                pageURL: URL(string: "https://example.com/beta2")!,
                draft: false,
                prerelease: true
            )
        ))
        guard case .untaggedBuild = try UpdateChecker.result(currentTag: nil, data: data) else {
            Issue.record("Expected an untagged build")
            return
        }
    }

    @Test
    func stableBuildIgnoresPrereleases() throws {
        let data = Data("""
        [
          {"tag_name":"v0.2.0-beta.1","html_url":"https://example.com/beta","draft":false,"prerelease":true},
          {"tag_name":"v0.1.1","html_url":"https://example.com/stable","draft":false,"prerelease":false}
        ]
        """.utf8)
        let result = try UpdateChecker.result(currentTag: "v0.1.0", data: data)
        guard case .updateAvailable(let release) = result else {
            Issue.record("Expected a stable update")
            return
        }
        #expect(release.tagName == "v0.1.1")
    }
}
