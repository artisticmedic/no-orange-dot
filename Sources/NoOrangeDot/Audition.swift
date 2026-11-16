import AVFoundation
import Foundation

/// Plays a raw take through the same processing chain as the mic, so the EQ can be changed, or
/// switched on and off, while the same words repeat. It also feeds the live spectrum.
final class AuditionPlayer {
    static let ringSize = 8192
    let rawRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    let postRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private(set) var ringIndex = 0
    let chain = DSPChain()
    private(set) var sampleRate = 48000.0
    private(set) var stereo = false
    private(set) var count = 0
    private(set) var position = 0
    private(set) var finished = false
    var loop = true
    var level: Float = 0
    var voiceLevel = VoiceLevel()

    private var left: UnsafeMutablePointer<Float>?
    private var right: UnsafeMutablePointer<Float>?
    private let workL = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private let workR = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var engine: AVAudioEngine?

    init() {
        rawRing.initialize(repeating: 0, count: Self.ringSize)
        postRing.initialize(repeating: 0, count: Self.ringSize)
    }

    var progress: Double { count > 0 ? Double(position) / Double(count) : 0 }
    var seconds: Double { Double(position) / sampleRate }

    func start(_ url: URL) -> Bool {
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
        left = l; right = r; count = n; position = 0; finished = false

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
        count = 0; position = 0; level = 0
        voiceLevel.reset()
    }

    private func render(_ frames: Int, _ out: UnsafeMutableAudioBufferListPointer) {
        let n = min(frames, 16384)
        guard let left, let right, count > 0, !finished else {
            for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        var pos = position
        for i in 0..<n {
            if pos >= count { if loop { pos = 0 } else { workL[i] = 0; workR[i] = 0; continue } }
            workL[i] = left[pos]; workR[i] = right[pos]; pos += 1
        }
        if pos >= count && !loop { finished = true }
        position = pos
        let mask = Self.ringSize - 1, at = ringIndex
        for i in 0..<n { rawRing[(at + i) & mask] = workL[i] }
        chain.process(workL, workR, frames: n, stereo: stereo)
        voiceLevel.consume(workL, workR, frames: n, stereo: stereo, sampleRate: sampleRate)
        var peak = level
        for i in 0..<n { postRing[(at + i) & mask] = workL[i]; let v = abs(workL[i]); if v > peak { peak = v } }
        level = peak
        ringIndex = (at + n) & mask
        if out.count > 0, let d = out[0].mData { memcpy(d, workL, n * 4) }
        if out.count > 1, let d = out[1].mData { memcpy(d, workR, n * 4) }
    }
}
