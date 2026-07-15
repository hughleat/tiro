import AppKit

final class RecordingSoundPlayer: NSObject, NSSoundDelegate {
    private var startSound: NSSound?
    private lazy var stopSound = Self.tone(frequency: 520, duration: 0.055)
    private var startCompletion: (() -> Void)?
    private var startWorkItem: DispatchWorkItem?

    func playStart(completion: @escaping () -> Void) {
        cancelStart()
        stopSound?.stop()
        let sound = Self.tone(frequency: 880, duration: 0.07)
        startSound = sound
        startCompletion = completion
        sound?.delegate = self
        if sound?.play() != true { finishStart(sound) }
    }

    func cancelStart() {
        startWorkItem?.cancel()
        startWorkItem = nil
        startCompletion = nil
        startSound?.stop()
        startSound = nil
    }

    func playStop() {
        stopSound?.stop()
        stopSound?.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        guard sound === startSound else { return }
        finishStart(sound)
    }

    private func finishStart(_ sound: NSSound?) {
        guard sound === startSound else { return }
        let workItem = DispatchWorkItem { [weak self, weak sound] in
            guard let self, sound === self.startSound else { return }
            self.startSound = nil
            let completion = self.startCompletion
            self.startCompletion = nil
            self.startWorkItem = nil
            completion?()
        }
        startWorkItem = workItem
        // Let the short cue decay before opening the microphone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
    }

    private static func tone(frequency: Double, duration: Double) -> NSSound? {
        let sampleRate = 44_100
        let count = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let position = Double(index) / Double(count)
            let envelope = min(1, position * 12) * min(1, (1 - position) * 12)
            let wave = sin(2 * .pi * frequency * Double(index) / Double(sampleRate))
            var sample = Int16(wave * envelope * 5_000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        func append(_ text: String) { wav.append(contentsOf: text.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
        }
        append("RIFF")
        appendLE(UInt32(36 + pcm.count))
        append("WAVEfmt ")
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1))
        appendLE(UInt32(sampleRate)); appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2)); appendLE(UInt16(16))
        append("data"); appendLE(UInt32(pcm.count)); wav.append(pcm)
        return NSSound(data: wav)
    }
}
