import Foundation

struct SupportPromptPolicy {
    private enum Key {
        static let firstLaunch = "supportPromptFirstLaunchDate"
        static let successfulTranscriptions = "supportPromptSuccessfulTranscriptions"
        static let lastShown = "supportPromptLastShownDate"
        static let alreadySupporting = "supportPromptAlreadySupporting"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let enabled: Bool

    init(
        enabled: Bool = BuildFeatures.sponsorshipEnabled,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.enabled = enabled
        self.defaults = defaults
        self.calendar = calendar
    }

    func registerLaunch(at date: Date = Date()) {
        guard enabled else { return }
        guard defaults.object(forKey: Key.firstLaunch) as? Date == nil else { return }
        defaults.set(date, forKey: Key.firstLaunch)
    }

    func recordSuccessfulTranscription() {
        guard enabled else { return }
        let count = max(0, defaults.integer(forKey: Key.successfulTranscriptions))
        defaults.set(min(20, count + (count < 20 ? 1 : 0)), forKey: Key.successfulTranscriptions)
    }

    func shouldPrompt(at date: Date = Date()) -> Bool {
        nextPromptDate(relativeTo: date).map { date >= $0 } ?? false
    }

    func nextPromptDate(relativeTo date: Date = Date()) -> Date? {
        guard enabled else { return nil }
        guard !defaults.bool(forKey: Key.alreadySupporting) else { return nil }
        if let lastShown = defaults.object(forKey: Key.lastShown) as? Date {
            return calendar.date(byAdding: .month, value: 6, to: lastShown)
        }

        let enoughTranscriptions = defaults.integer(forKey: Key.successfulTranscriptions) >= 20
        if enoughTranscriptions { return date }
        guard let firstLaunch = defaults.object(forKey: Key.firstLaunch) as? Date,
              let firstDatePrompt = calendar.date(byAdding: .day, value: 7, to: firstLaunch) else {
            return nil
        }
        return firstDatePrompt
    }

    func markShown(at date: Date = Date()) {
        guard enabled else { return }
        defaults.set(date, forKey: Key.lastShown)
    }

    func markAlreadySupporting() {
        guard enabled else { return }
        defaults.set(true, forKey: Key.alreadySupporting)
    }
}

struct SupportPromptPresentationState {
    let isIdle: Bool
    let setupCompleted: Bool
    let onboardingVisible: Bool
    let presentingRecovery: Bool
    let overlayVisible: Bool
    let promptVisible: Bool
    let suppressedUntil: Date?

    func canPresent(at date: Date = Date()) -> Bool {
        isIdle
            && setupCompleted
            && !onboardingVisible
            && !presentingRecovery
            && !overlayVisible
            && !promptVisible
            && (suppressedUntil.map { date >= $0 } ?? true)
    }
}
