import AVFoundation
import Foundation

@MainActor
final class ReferenceVoice: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = ReferenceVoice()
    static let text = "This is a reference speaking voice. Keep your headphones or speakers at the same volume, then compare your own voice."

    static var referenceVoice: AVSpeechSynthesisVoice? {
        let identifiers = ["com.apple.voice.compact.en-US.Samantha", "com.apple.speech.synthesis.voice.samantha", "com.apple.speech.synthesis.voice.Alex"]
        let installed = AVSpeechSynthesisVoice.speechVoices()
        return identifiers.lazy.compactMap { id in installed.first { $0.identifier == id } }.first
    }

    enum State: Equatable {
        case idle, preparing, playing, failed(String)
    }
    @Published private(set) var state: State = .idle
    var isActive: Bool { state == .preparing || state == .playing }
    private var synthesizer: AVSpeechSynthesizer?
    private var player: AVAudioPlayer?
    private var cachedWave: Data?
    private var generation = UUID()
    private var samples: [Float] = []
    private var sampleRate = 0.0
    private var timeout: Task<Void, Never>?

    func toggle() {
        switch state {
        case .preparing, .playing: stop()
        case .idle, .failed: prepare()
        }
    }

    func stop() {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        player?.stop(); player = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil
        samples.removeAll(keepingCapacity: false)
        sampleRate = 0
        state = .idle
    }

    private func prepare() {
        stop()
        if let cachedWave { play(cachedWave); return }
        guard let voice = Self.referenceVoice else {
            state = .failed("The built-in English reference voice isn't available on this Mac.")
            return
        }
        state = .preparing
        let token = generation
        let speech = AVSpeechSynthesizer()
        speech.delegate = self
        synthesizer = speech
        let utterance = AVSpeechUtterance(string: Self.text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.generation == token, self.state == .preparing else { return }
            self.fail("The reference voice took too long to prepare. Try again.")
        }
        speech.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail("The reference voice returned an unsupported audio format.")
                }
                return
            }
            let chunk = ReferenceAudio.monoSamples(pcm)
            let rate = pcm.format.sampleRate
            let ended = pcm.frameLength == 0
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.state == .preparing else { return }
                if ended { self.playPrepared(); return }
                guard let chunk, rate.isFinite, rate > 0, self.sampleRate == 0 || self.sampleRate == rate else {
                    self.fail("The reference voice returned an unsupported audio format.")
                    return
                }
                self.sampleRate = rate
                self.samples.append(contentsOf: chunk)
            }
        }
    }

    private func playPrepared() {
        timeout?.cancel(); timeout = nil
        guard let normalized = ReferenceAudio.normalized(samples, sampleRate: sampleRate),
              let wave = ReferenceAudio.wave(normalized, sampleRate: sampleRate) else {
            fail("The reference voice didn't produce usable audio. Try again.")
            return
        }
        samples.removeAll(keepingCapacity: false)
        cachedWave = wave
        play(wave)
    }

    private func play(_ wave: Data) {
        do {
            let audio = try AVAudioPlayer(data: wave)
            audio.delegate = self
            player = audio
            guard audio.play() else { fail("Couldn't play the reference voice through the Mac's output."); return }
            state = .playing
        } catch {
            fail("Couldn't prepare the reference voice for playback: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) { stop(); state = .failed(message) }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if flag { self.stop() } else { self.fail("The reference voice stopped before it finished playing.") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.fail("Couldn't decode the reference voice for playback.")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.synthesizer === synthesizer, self.state == .preparing else { return }
            self.fail("The reference voice was interrupted while preparing. Try again.")
        }
    }
}

enum ReferenceAudio {
    static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount), stride = buffer.stride
        guard frames > 0, channels > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            for frame in 0..<frames {
                let index = frame * stride
                let value: Float
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let data = buffer.floatChannelData else { return nil }
                    value = data[channel][index]
                case .pcmFormatInt16:
                    guard let data = buffer.int16ChannelData else { return nil }
                    value = Float(data[channel][index]) / 32768
                case .pcmFormatInt32:
                    guard let data = buffer.int32ChannelData else { return nil }
                    value = Float(Double(data[channel][index]) / 2147483648)
                default: return nil
                }
                samples[frame] += value / Float(channels)
            }
        }
        return samples
    }

    /// RMS of active 20 ms windows excludes the gaps between words.
    static func activeRMS(_ samples: [Float], sampleRate: Double) -> Double? {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate >= 1, sampleRate <= 384000,
              samples.allSatisfy(\.isFinite) else { return nil }
        let peak = Double(samples.lazy.map { abs($0) }.max() ?? 0)
        let threshold = max(pow(10, VoiceLevel.signalFloorDB / 20), peak * 0.01)
        let window = max(1, Int(sampleRate * 0.02))
        var sum = 0.0, count = 0
        var at = 0
        while at < samples.count {
            let end = min(samples.count, at + window)
            var power = 0.0
            for i in at..<end { power += Double(samples[i]) * Double(samples[i]) }
            if power / Double(end - at) >= threshold * threshold { sum += power; count += end - at }
            at = end
        }
        return count > 0 ? sqrt(sum / Double(count)) : nil
    }

    static func normalized(_ samples: [Float], sampleRate: Double) -> [Float]? {
        guard let rms = activeRMS(samples, sampleRate: sampleRate), rms > 0 else { return nil }
        let peak = Double(samples.lazy.map { abs($0) }.max() ?? 0)
        let gain = min(pow(10, VoiceLevel.referenceDB / 20) / rms, pow(10, -3.0 / 20) / peak)
        return samples.map { Float(Double($0) * gain) }
    }

    static func wave(_ samples: [Float], sampleRate: Double) -> Data? {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 384000,
              samples.count <= (Int(UInt32.max) - 36) / 2, samples.allSatisfy(\.isFinite) else { return nil }
        let bytes = UInt32(samples.count * 2), rate = UInt32(sampleRate.rounded())
        var data = Data(capacity: 44 + Int(bytes))
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(bytes + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(rate); word(rate * 2); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(bytes)
        for sample in samples { word(Int16((min(max(Double(sample), -1), 1) * 32767).rounded())) }
        return data
    }
}
