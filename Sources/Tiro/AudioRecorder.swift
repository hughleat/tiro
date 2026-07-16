import AVFoundation
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let levelLock = NSLock()
    private var samples: [Float] = []
    private var level: Float = 0
    private var inputSampleRate = 48_000.0
    private(set) var isRecording = false

    var normalizedMicrophoneLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return level
    }

    func start() throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RecorderError.noInput
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        setLevel(0)
        inputSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            self.publishLevel(from: channel, count: frameCount)
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        setLevel(0)

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !captured.isEmpty else { throw RecorderError.emptyRecording }
        let output = Self.resample(captured, from: inputSampleRate, to: 16_000)
        try PrivateFilePermissions.ensureDirectory(at: AppPaths.transientRecordingsDirectory)
        let url = AppPaths.transientRecordingsDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).wav")
        try PrivateFilePermissions.write(Self.wavData(samples: output, sampleRate: 16_000), to: url)
        return url
    }

    static func removeStaleRecordings() {
        guard FileManager.default.fileExists(atPath: AppPaths.transientRecordingsDirectory.path) else {
            return
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: AppPaths.transientRecordingsDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            NSLog("Could not inspect stale Tiro recordings: %@", error.localizedDescription)
            return
        }
        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                NSLog("Could not remove stale Tiro recording: %@", error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        setLevel(0)
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func publishLevel(from samples: UnsafePointer<Float>, count: Int) {
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (decibels + 60) / 60))

        guard levelLock.try() else { return }
        level = normalized
        levelLock.unlock()
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        level = value
        levelLock.unlock()
    }

    private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate != targetRate else { return input }
        let outputCount = Int((Double(input.count) * targetRate / sourceRate).rounded())
        let ratio = sourceRate / targetRate
        return (0..<outputCount).map { index in
            let position = Double(index) * ratio
            let left = Int(position)
            let right = min(left + 1, input.count - 1)
            let mix = Float(position - Double(left))
            return input[left] * (1 - mix) + input[right] * mix
        }
    }

    private static func wavData(samples: [Float], sampleRate: UInt32) -> Data {
        var data = Data()
        func appendString(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        appendString("RIFF")
        appendLE(UInt32(36) + byteCount)
        appendString("WAVE")
        appendString("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(sampleRate * 2)
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        appendString("data")
        appendLE(byteCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            appendLE(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}

enum RecorderError: LocalizedError {
    case noInput
    case notRecording
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input is available."
        case .notRecording: return "Recording has not started."
        case .emptyRecording: return "The recording was empty."
        }
    }
}
