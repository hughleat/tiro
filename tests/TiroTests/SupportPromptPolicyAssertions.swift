import Foundation

@main
struct SupportPromptPolicyAssertions {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let launch = Date(timeIntervalSince1970: 1_700_000_000)

        let datePolicy = makePolicy(calendar: calendar)
        datePolicy.registerLaunch(at: launch)
        let sevenDays = calendar.date(byAdding: .day, value: 7, to: launch)!
        assert(!datePolicy.shouldPrompt(at: sevenDays.addingTimeInterval(-1)))
        assert(datePolicy.shouldPrompt(at: sevenDays))

        let countPolicy = makePolicy(calendar: calendar)
        countPolicy.registerLaunch(at: launch)
        for _ in 0..<19 { countPolicy.recordSuccessfulTranscription() }
        assert(!countPolicy.shouldPrompt(at: launch))
        countPolicy.recordSuccessfulTranscription()
        assert(countPolicy.shouldPrompt(at: launch))
        for _ in 0..<30 { countPolicy.recordSuccessfulTranscription() }

        let recurringPolicy = makePolicy(calendar: calendar)
        let shown = calendar.date(from: DateComponents(year: 2024, month: 8, day: 31))!
        recurringPolicy.markShown(at: shown)
        let next = calendar.date(byAdding: .month, value: 6, to: shown)!
        assert(!recurringPolicy.shouldPrompt(at: next.addingTimeInterval(-1)))
        assert(recurringPolicy.shouldPrompt(at: next))

        recurringPolicy.markAlreadySupporting()
        assert(!recurringPolicy.shouldPrompt(at: calendar.date(byAdding: .year, value: 10, to: shown)!))

        let safe = SupportPromptPresentationState(
            isIdle: true,
            setupCompleted: true,
            onboardingVisible: false,
            presentingRecovery: false,
            overlayVisible: false,
            promptVisible: false,
            suppressedUntil: nil
        )
        assert(safe.canPresent(at: launch))
        assert(!SupportPromptPresentationState(
            isIdle: true,
            setupCompleted: true,
            onboardingVisible: false,
            presentingRecovery: true,
            overlayVisible: false,
            promptVisible: false,
            suppressedUntil: nil
        ).canPresent(at: launch))
        print("Support prompt policy assertions passed")
    }

    private static func makePolicy(calendar: Calendar) -> SupportPromptPolicy {
        let name = "SupportPromptPolicyAssertions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SupportPromptPolicy(defaults: defaults, calendar: calendar)
    }
}
