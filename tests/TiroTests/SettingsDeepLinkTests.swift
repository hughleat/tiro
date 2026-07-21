import Foundation
import Testing
@testable import Tiro

struct SettingsDeepLinkTests {
    @Test
    func opensSettingsSections() throws {
        #expect(SettingsSection(deepLink: try #require(URL(string: "tiro://settings"))) == .general)
        for section in SettingsSection.allCases {
            let url = try #require(URL(string: "tiro://settings/\(section.rawValue)"))
            #expect(SettingsSection(deepLink: url) == section)
        }
    }

    @Test
    func rejectsUnknownLinks() throws {
        #expect(SettingsSection(deepLink: try #require(URL(string: "https://example.com/settings"))) == nil)
        #expect(SettingsSection(deepLink: try #require(URL(string: "tiro://unknown/models"))) == nil)
        #expect(SettingsSection(deepLink: try #require(URL(string: "tiro://settings/unknown"))) == nil)
        #expect(SettingsSection(deepLink: try #require(URL(string: "tiro://settings/models/extra"))) == nil)
    }
}
