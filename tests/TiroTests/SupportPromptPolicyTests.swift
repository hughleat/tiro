import AppKit
import Foundation
import Testing
@testable import Tiro

@Suite
struct SupportPromptPolicyTests {
    private func makeDefaults() -> UserDefaults {
        let name = "SupportPromptPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func firstPromptUsesSevenDaysOrTwentyTranscriptions() {
        let defaults = makeDefaults()
        let policy = SupportPromptPolicy(enabled: true, defaults: defaults, calendar: calendar)
        let launch = Date(timeIntervalSince1970: 1_700_000_000)
        policy.registerLaunch(at: launch)

        #expect(!policy.shouldPrompt(at: calendar.date(byAdding: .day, value: 7, to: launch)!.addingTimeInterval(-1)))
        #expect(policy.shouldPrompt(at: calendar.date(byAdding: .day, value: 7, to: launch)!))

        let countDefaults = makeDefaults()
        let countPolicy = SupportPromptPolicy(enabled: true, defaults: countDefaults, calendar: calendar)
        countPolicy.registerLaunch(at: launch)
        for _ in 0..<19 { countPolicy.recordSuccessfulTranscription() }
        #expect(!countPolicy.shouldPrompt(at: launch))
        countPolicy.recordSuccessfulTranscription()
        #expect(countPolicy.shouldPrompt(at: launch))
    }

    @Test
    func recurringPromptUsesSixCalendarMonths() {
        let defaults = makeDefaults()
        let policy = SupportPromptPolicy(enabled: true, defaults: defaults, calendar: calendar)
        let shown = calendar.date(from: DateComponents(year: 2024, month: 8, day: 31))!
        policy.markShown(at: shown)
        let next = calendar.date(byAdding: .month, value: 6, to: shown)!

        #expect(!policy.shouldPrompt(at: next.addingTimeInterval(-1)))
        #expect(policy.shouldPrompt(at: next))
        #expect(policy.nextPromptDate(relativeTo: shown) == next)
    }

    @Test
    func alreadySupportingPermanentlySuppressesPrompts() {
        let defaults = makeDefaults()
        let policy = SupportPromptPolicy(enabled: true, defaults: defaults, calendar: calendar)
        let launch = Date(timeIntervalSince1970: 1_700_000_000)
        policy.registerLaunch(at: launch)
        policy.markAlreadySupporting()

        #expect(!policy.shouldPrompt(at: calendar.date(byAdding: .year, value: 10, to: launch)!))
    }

    @Test
    func successfulTranscriptionCountSaturatesAndMalformedValuesRecover() {
        let defaults = makeDefaults()
        defaults.set(Int.max, forKey: "supportPromptSuccessfulTranscriptions")
        defaults.set("not a date", forKey: "supportPromptFirstLaunchDate")
        let policy = SupportPromptPolicy(enabled: true, defaults: defaults, calendar: calendar)

        policy.recordSuccessfulTranscription()
        policy.registerLaunch(at: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(defaults.integer(forKey: "supportPromptSuccessfulTranscriptions") == 20)
        #expect(policy.shouldPrompt(at: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(policy.nextPromptDate(relativeTo: Date(timeIntervalSince1970: 1_700_000_000))
            == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func presentationRequiresEverySafetyCondition() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ready = SupportPromptPresentationState(
            isIdle: true,
            setupCompleted: true,
            onboardingVisible: false,
            presentingRecovery: false,
            overlayVisible: false,
            promptVisible: false,
            suppressedUntil: nil
        )
        #expect(ready.canPresent(at: now))

        #expect(!SupportPromptPresentationState(
            isIdle: false, setupCompleted: true, onboardingVisible: false,
            presentingRecovery: false, overlayVisible: false, promptVisible: false,
            suppressedUntil: nil
        ).canPresent(at: now))
        #expect(!SupportPromptPresentationState(
            isIdle: true, setupCompleted: false, onboardingVisible: false,
            presentingRecovery: false, overlayVisible: false, promptVisible: false,
            suppressedUntil: nil
        ).canPresent(at: now))
        #expect(!SupportPromptPresentationState(
            isIdle: true, setupCompleted: true, onboardingVisible: true,
            presentingRecovery: false, overlayVisible: false, promptVisible: false,
            suppressedUntil: nil
        ).canPresent(at: now))
        #expect(!SupportPromptPresentationState(
            isIdle: true, setupCompleted: true, onboardingVisible: false,
            presentingRecovery: true, overlayVisible: false, promptVisible: false,
            suppressedUntil: nil
        ).canPresent(at: now))
        #expect(!SupportPromptPresentationState(
            isIdle: true, setupCompleted: true, onboardingVisible: false,
            presentingRecovery: false, overlayVisible: true, promptVisible: false,
            suppressedUntil: nil
        ).canPresent(at: now))
        #expect(!SupportPromptPresentationState(
            isIdle: true, setupCompleted: true, onboardingVisible: false,
            presentingRecovery: false, overlayVisible: false, promptVisible: true,
            suppressedUntil: nil
        ).canPresent(at: now))
        #expect(!SupportPromptPresentationState(
            isIdle: true, setupCompleted: true, onboardingVisible: false,
            presentingRecovery: false, overlayVisible: false, promptVisible: false,
            suppressedUntil: now.addingTimeInterval(1)
        ).canPresent(at: now))
    }

    @Test
    func registrationDoesNotOverwriteFirstLaunch() {
        let defaults = makeDefaults()
        let policy = SupportPromptPolicy(enabled: true, defaults: defaults, calendar: calendar)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        policy.registerLaunch(at: first)
        policy.registerLaunch(at: first.addingTimeInterval(1_000))

        #expect(!policy.shouldPrompt(at: calendar.date(byAdding: .day, value: 7, to: first)!.addingTimeInterval(-1)))
        #expect(policy.shouldPrompt(at: calendar.date(byAdding: .day, value: 7, to: first)!))
    }

    @Test
    func disabledPolicyDoesNotStoreOrScheduleAnything() {
        let defaults = makeDefaults()
        let policy = SupportPromptPolicy(
            enabled: false,
            defaults: defaults,
            calendar: calendar
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        policy.registerLaunch(at: now)
        policy.recordSuccessfulTranscription()
        policy.markShown(at: now)
        policy.markAlreadySupporting()

        for key in [
            "supportPromptFirstLaunchDate",
            "supportPromptSuccessfulTranscriptions",
            "supportPromptLastShownDate",
            "supportPromptAlreadySupporting",
        ] {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(!policy.shouldPrompt(at: now))
        #expect(policy.nextPromptDate(relativeTo: now) == nil)
    }

#if TIRO_SPONSORSHIP_ENABLED
    @Test @MainActor
    func promptHasExpectedCopyAndExactlyTwoActions() {
        _ = NSApplication.shared
        let controller = SupportPromptWindowController()
        let buttons = controller.window?.contentView?.subviews
            .flatMap(Self.visibleButtons(in:)) ?? []

        #expect(SupportPromptWindowController.messageText.contains("Sorry for the interruption"))
        #expect(SupportPromptWindowController.messageText.contains("once every six months"))
        #expect(buttons.count == 2)
        #expect(buttons.map(\.title).sorted() == ["I already support", "Support Tiro"])
        #expect(controller.window?.styleMask.contains(.closable) == true)
    }

    @MainActor
    private static func visibleButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            if let button = child as? NSButton, !button.isHidden {
                return [button]
            }
            return visibleButtons(in: child)
        }
    }
#endif
}
