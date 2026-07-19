import AVFoundation
import Foundation
import Speech

public struct AppleSpeechOptions: Equatable, Sendable {
    public let localeIdentifier: String
    public let contextualStrings: [String]

    public init(localeIdentifier: String, contextualStrings: [String] = []) {
        self.localeIdentifier = localeIdentifier
        self.contextualStrings = Array(contextualStrings.prefix(100))
    }
}

public struct AppleSpeechTranscript: Equatable, Sendable {
    public let text: String
    public let audioSeconds: Double
    public let transcriptionSeconds: Double

    public init(text: String, audioSeconds: Double, transcriptionSeconds: Double) {
        self.text = text
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
    }
}

public enum AppleSpeechError: LocalizedError {
    case permissionDenied
    case localeUnavailable(String)
    case onDeviceRecognitionUnavailable(String)
    case emptyTranscription

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech Recognition permission is required to use Apple Speech."
        case .localeUnavailable(let locale):
            "Apple Speech does not support \(locale) on this Mac."
        case .onDeviceRecognitionUnavailable(let locale):
            "On-device Apple Speech is unavailable for \(locale) on this Mac."
        case .emptyTranscription:
            "Apple Speech returned an empty transcription."
        }
    }
}

public struct AppleSpeechAvailability: Equatable, Sendable {
    public enum State: String, Sendable {
        case permissionRequired = "permission_required"
        case unavailable
        case ready
    }

    public let state: State

    public var permissionGranted: Bool { state != .permissionRequired }
    public var usable: Bool { state == .ready }
}

protocol AppleSpeechRuntime: Sendable {
    func transcribe(
        _ audioURL: URL,
        options: AppleSpeechOptions
    ) async throws -> AppleSpeechTranscript
}

struct SystemAppleSpeechRuntime: AppleSpeechRuntime {
    func transcribe(
        _ audioURL: URL,
        options: AppleSpeechOptions
    ) async throws -> AppleSpeechTranscript {
        guard await Self.authorizationStatus() == .authorized else {
            throw AppleSpeechError.permissionDenied
        }
        return try await transcribeWithLegacyRecognizer(audioURL, options: options)
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func result(
        text: String,
        file: AVAudioFile,
        elapsed: TimeInterval
    ) throws -> AppleSpeechTranscript {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppleSpeechError.emptyTranscription }
        let duration = file.processingFormat.sampleRate > 0
            ? Double(file.length) / file.processingFormat.sampleRate
            : 0
        return AppleSpeechTranscript(
            text: text,
            audioSeconds: duration,
            transcriptionSeconds: elapsed
        )
    }

    private func transcribeWithLegacyRecognizer(
        _ audioURL: URL,
        options: AppleSpeechOptions
    ) async throws -> AppleSpeechTranscript {
        let requestedLocale = Locale(identifier: options.localeIdentifier)
        guard let locale = AppleSpeechLocaleResolver.resolve(
            requested: requestedLocale,
            supported: SFSpeechRecognizer.supportedLocales()
        ), let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppleSpeechError.localeUnavailable(options.localeIdentifier)
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechError.onDeviceRecognitionUnavailable(options.localeIdentifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = options.contextualStrings
        let file = try AVAudioFile(forReading: audioURL)
        let start = Date()
        let text = try await LegacyRecognitionTask.recognize(using: recognizer, request: request)
        return try result(text: text, file: file, elapsed: Date().timeIntervalSince(start))
    }
}

enum AppleSpeechLocaleResolver {
    static func resolve(
        requested: Locale,
        supported: Set<Locale>,
        current: Locale = .current
    ) -> Locale? {
        let normalizedIdentifier = requested.identifier.replacingOccurrences(of: "_", with: "-")
        if let exact = supported.first(where: {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
                .caseInsensitiveCompare(normalizedIdentifier) == .orderedSame
        }) {
            return exact
        }

        guard let language = requested.language.languageCode?.identifier else { return nil }
        let candidates = supported.filter {
            $0.language.languageCode?.identifier == language
        }
        guard !candidates.isEmpty else { return nil }

        let preferredRegion = requested.region?.identifier
            ?? (current.language.languageCode?.identifier == language
                ? current.region?.identifier
                : nil)
        if let preferredRegion, let regional = candidates.first(where: {
            $0.region?.identifier == preferredRegion
        }) {
            return regional
        }
        return candidates.sorted { $0.identifier < $1.identifier }.first
    }
}

private final class LegacyRecognitionTask: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    static func recognize(
        using recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest
    ) async throws -> String {
        let operation = LegacyRecognitionTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(
                    using: recognizer,
                    request: request,
                    continuation: continuation
                )
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func start(
        using recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest,
        continuation: CheckedContinuation<String, Error>
    ) {
        let shouldStart = lock.withLock {
            guard !cancelled else { return false }
            self.continuation = continuation
            return true
        }
        guard shouldStart else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error {
                self?.finish(.failure(error))
            } else if let result, result.isFinal {
                self?.finish(.success(result.bestTranscription.formattedString))
            }
        }
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled || self.continuation == nil
        }
        if shouldCancel {
            task.cancel()
            lock.withLock { self.task = nil }
        }
    }

    private func cancel() {
        let (task, continuation) = lock.withLock {
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return (self.task, continuation)
        }
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<String, Error>) {
        let continuation = lock.withLock {
            defer {
                self.continuation = nil
                task = nil
            }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

public actor AppleSpeechEngine {
    private let runtime: any AppleSpeechRuntime

    public init() {
        runtime = SystemAppleSpeechRuntime()
    }

    init(runtime: any AppleSpeechRuntime) {
        self.runtime = runtime
    }

    public func transcribe(
        _ audioURL: URL,
        options: AppleSpeechOptions
    ) async throws -> AppleSpeechTranscript {
        try await runtime.transcribe(audioURL, options: options)
    }

    public nonisolated static func availability(
        localeIdentifier: String
    ) -> AppleSpeechAvailability {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return AppleSpeechAvailability(state: .permissionRequired)
        }
        let requested = Locale(identifier: localeIdentifier)
        guard let locale = AppleSpeechLocaleResolver.resolve(
            requested: requested,
            supported: SFSpeechRecognizer.supportedLocales()
        ), let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            return AppleSpeechAvailability(state: .unavailable)
        }
        return AppleSpeechAvailability(state: .ready)
    }

    public nonisolated static func supports(localeIdentifier: String) -> Bool {
        let requested = Locale(identifier: localeIdentifier)
        guard let locale = AppleSpeechLocaleResolver.resolve(
            requested: requested,
            supported: SFSpeechRecognizer.supportedLocales()
        ), let recognizer = SFSpeechRecognizer(locale: locale) else {
            return false
        }
        return recognizer.supportsOnDeviceRecognition
    }
}
