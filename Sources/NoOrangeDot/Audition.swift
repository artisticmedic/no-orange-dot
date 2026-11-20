import AVFoundation
import Foundation

/// Plays a recording. A raw take goes through the same processing chain as the mic, so the sound can be
/// changed while the same words repeat; a take saved without its raw audio plays as saved. It also feeds
/// the live spectrum. Pause, seek and the loop range are set from the main thread and picked up by the
/// audio thread on its next block.
final class AuditionPlayer {
    static let ringSize = 8192
    /// About 5 ms: long enough to hide the click at a seek, a loop edge or a pause.
    static let fadeFrames = 240
    let rawRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    let postRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private(set) var ringIndex = 0
    let chain = DSPChain()
    private(set) var sampleRate = 48000.0
    private(set) var stereo = false
    private(set) var count = 0
    private(set) var position = 0
    private(set) var finished = false
    /// False plays the file as saved, without the processing chain.
    private(set) var processing = true
    /// Loudest sample in each of `peakCount` slices of the file, for drawing it.
    private(set) var peaks: [Float] = []
    static let peakCount = 600
    var loop = true
    var paused = false
    var level: Float = 0
    var voiceLevel = VoiceLevel()

    private var left: UnsafeMutablePointer<Float>?
    private var right: UnsafeMutablePointer<Float>?
    private let workL = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private let workR = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var engine: AVAudioEngine?
    private var rangeStart = 0, rangeEnd = 0
    private var seekTo = -1
    private var fadeIn = 0
    private var silent = false

    init() {
        rawRing.initialize(repeating: 0, count: Self.ringSize)
        postRing.initialize(repeating: 0, count: Self.ringSize)
    }

    var progress: Double { count > 0 ? Double(position) / Double(count) : 0 }
    var seconds: Double { Double(position) / sampleRate }
    var duration: Double { Double(count) / sampleRate }

    func start(_ url: URL, processing: Bool = true, from second: Double = 0, paused: Bool = false) -> Bool {
        stop()
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return false }
        let n = Int(buffer.frameLength)
        stereo = file.processingFormat.channelCount >= 2
        sampleRate = file.processingFormat.sampleRate
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        l.update(from: data[0], count: n)
        r.update(from: stereo ? data[1] : data[0], count: n)
        left = l; right = r; count = n; finished = false
        rangeStart = 0; rangeEnd = n
        position = min(max(Int(second * sampleRate), 0), n - 1)
        self.processing = processing
        self.paused = paused
        silent = paused
        fadeIn = Self.fadeFrames
        peaks = Self.peaks(l, count: n)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: stereo ? 2 : 1) else { return false }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list in
            self.render(Int(frameCount), UnsafeMutableAudioBufferListPointer(list))
            return noErr
        }
        let e = AVAudioEngine()
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        do { try e.start() } catch { return false }
        engine = e
        return true
    }

    func stop() {
        engine?.stop()
        engine = nil
        left?.deallocate(); right?.deallocate()
        left = nil; right = nil
        count = 0; position = 0; level = 0; peaks = []
        voiceLevel.reset()
    }

    func seek(to second: Double) {
        guard count > 0 else { return }
        seekTo = min(max(Int(second * sampleRate), 0), count - 1)
        position = seekTo
        finished = false
    }

    /// Where a loop goes back to, and where playback stops or loops. Nil plays the whole file.
    func setRange(_ seconds: ClosedRange<Double>?) {
        guard count > 0 else { return }
        guard let seconds else { rangeStart = 0; rangeEnd = count; return }
        let a = min(max(Int(seconds.lowerBound * sampleRate), 0), count - 1)
        rangeEnd = min(max(Int(seconds.upperBound * sampleRate), a + 1), count)
        rangeStart = a
    }

    static func peaks(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let slice = max(count / peakCount, 1)
        return stride(from: 0, to: count, by: slice).map { i in
            var m: Float = 0
            for k in i..<min(i + slice, count) { let v = abs(samples[k]); if v > m { m = v } }
            return m
        }
    }

    private func render(_ frames: Int, _ out: UnsafeMutableAudioBufferListPointer) {
        let n = min(frames, 16384)
        guard let left, let right, count > 0, !finished else {
            for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        if seekTo >= 0 { position = seekTo; seekTo = -1; fadeIn = Self.fadeFrames }
        // Pausing plays one more block, faded out; resuming fades back in.
        if paused && silent {
            for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            level = 0
            return
        }
        let fadingOut = paused
        if !paused && silent { silent = false; fadeIn = Self.fadeFrames }
        let fade = Float(Self.fadeFrames)
        let lo = rangeStart, hi = rangeEnd
        var pos = position
        // A selection keeps playback inside it: a playhead before it jumps to its start.
        if pos < lo { pos = lo; fadeIn = Self.fadeFrames }
        for i in 0..<n {
            if pos >= hi {
                if loop { pos = lo; fadeIn = Self.fadeFrames }
                else { finished = true; for k in i..<n { workL[k] = 0; workR[k] = 0 }; break }
            }
            var g: Float = 1
            if fadeIn > 0 { g = 1 - Float(fadeIn) / fade; fadeIn -= 1 }
            let remaining = hi - pos
            if remaining < Self.fadeFrames { g *= Float(remaining) / fade }
            if fadingOut { g *= 1 - Float(i) / Float(n) }
            workL[i] = left[pos] * g; workR[i] = right[pos] * g
            pos += 1
        }
        if fadingOut { silent = true }
        position = pos
        let mask = Self.ringSize - 1, at = ringIndex
        for i in 0..<n { rawRing[(at + i) & mask] = workL[i] }
        if processing { chain.process(workL, workR, frames: n, stereo: stereo) }
        voiceLevel.consume(workL, workR, frames: n, stereo: stereo, sampleRate: sampleRate)
        var peak = level
        for i in 0..<n { postRing[(at + i) & mask] = workL[i]; let v = abs(workL[i]); if v > peak { peak = v } }
        level = peak
        ringIndex = (at + n) & mask
        if out.count > 0, let d = out[0].mData { memcpy(d, workL, n * 4) }
        if out.count > 1, let d = out[1].mData { memcpy(d, workR, n * 4) }
    }
}
