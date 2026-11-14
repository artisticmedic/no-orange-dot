import AVFoundation
import Accelerate
import Foundation

/// A windowed FFT that returns power per bin, scaled so a full-scale sine reads 0 dB.
final class Spectrum {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var real: [Float], imag: [Float], scratch: [Float]

    init(size: Int = 4096) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        scratch = [Float](repeating: 0, count: size)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Power in each of `size / 2` bins for `size` samples at `x`.
    func power(_ x: UnsafePointer<Float>, into out: inout [Float]) {
        vDSP_vmul(x, 1, window, 1, &scratch, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                scratch.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &out, 1, vDSP_Length(size / 2))
            }
        }
        var scale = 1 / Float(size / 2 * size / 2)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(size / 2))
    }

    /// Level in dB of fractional-octave bands centred on `centres`, from per-bin power.
    static func bands(power: [Float], sampleRate: Double, centres: [Double], fraction: Double) -> [Double] {
        let binHz = sampleRate / Double(power.count * 2)
        func density(_ f: Double) -> Double {
            let x = f / binHz, i = Int(x)
            guard i + 1 < power.count else { return Double(power[power.count - 1]) }
            let t = x - Double(i)
            return Double(power[i]) * (1 - t) + Double(power[i + 1]) * t
        }
        let half = pow(2, 1 / (2 * fraction))
        return centres.map { fc in
            let lo = fc / half, hi = min(fc * half, sampleRate / 2 - binHz)
            let steps = max(5, Int((hi - lo) / binHz) + 1)
            var sum = 0.0
            for k in 0..<steps { sum += density(lo + (hi - lo) * (Double(k) + 0.5) / Double(steps)) }
            return 10 * log10(max(sum / Double(steps) * (hi - lo) / binHz, 1e-20))
        }
    }
}

/// Works out an EQ for a voice: measure the average tone of some speech, compare it with a target
/// for clear speech, and fit a few bands that close the gap.
enum AutoEQ {
    enum Target: String, CaseIterable, Codable { case warm, neutral, bright
        var label: String { rawValue.capitalized }
    }

    struct Result: Codable {
        var target: Target
        var strength: Double
        var secondsOfSpeech: Double
        var bands: [Band]
        var offBeforeDB: Double   // how far the voice was from the target, on average
        var offAfterDB: Double    // how far it should be with these bands
        var centres: [Double]
        var measured: [Double]    // dB per band, the voice as recorded
        var wanted: [Double]      // dB per band, the target at the same loudness
    }

    /// Sixth-octave centres from 80 Hz to 12 kHz.
    static let centres: [Double] = (0...43).map { 80 * pow(2, Double($0) / 6) }.filter { $0 <= 12500 }

    /// Long-term average speech levels in third-octave bands. After Byrne et al. (1994), smoothed.
    /// Only the shape matters; the fit matches loudness before comparing.
    private static let speech: [(Double, Double)] = [
        (63, 38.6), (80, 43.5), (100, 54.4), (125, 57.7), (160, 56.8), (200, 60.2), (250, 60.3), (315, 59.0), (400, 62.1),
        (500, 62.1), (630, 60.5), (800, 56.8), (1000, 53.7), (1250, 53.0), (1600, 52.0), (2000, 48.7), (2500, 48.1),
        (3150, 46.8), (4000, 45.6), (5000, 44.5), (6300, 44.3), (8000, 43.7), (10000, 43.4), (12500, 41.3), (16000, 40.7),
    ]

    static func targetCurve(_ t: Target) -> [Double] {
        centres.map { f in
            let x = log2(f)
            var i = 0
            while i + 2 < speech.count, log2(speech[i + 1].0) < x { i += 1 }
            let a = speech[i], b = speech[i + 1]
            let u = min(max((x - log2(a.0)) / (log2(b.0) - log2(a.0)), 0), 1)
            var v = a.1 + (b.1 - a.1) * u - 10 * log10(2)   // a sixth-octave band holds half a third-octave band's power
            switch t {
            case .neutral: break
            case .warm: v += 4.5 * smooth(260 / f) - 1.0 * smooth(f / 5000)
            case .bright: v += 2.5 * smooth(f / 3500) - 1.0 * smooth(220 / f)
            }
            return v
        }
    }
    /// 0 well below the corner, 1 well above it, for a ratio of frequency to corner.
    private static func smooth(_ ratio: Double) -> Double { 1 / (1 + pow(ratio, -3)) }

    /// The average tone of the spoken parts of a recording, in dB per sixth-octave band.
    static func measure(_ samples: [Float], sampleRate: Double) -> (levels: [Double], seconds: Double)? {
        let n = 4096, hop = 2048
        guard samples.count >= n * 4 else { return nil }
        let fft = Spectrum(size: n)
        var frames: [(rms: Float, start: Int)] = []
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i + n <= samples.count {
                var rms: Float = 0
                vDSP_rmsqv(p.baseAddress! + i, 1, &rms, vDSP_Length(n))
                frames.append((rms, i)); i += hop
            }
        }
        // Speech only: frames within 30 dB of the loudest, so pauses and room noise don't count.
        guard let loudest = frames.map(\.rms).max(), loudest > 0.01 else { return nil }   // quieter than -40 dBFS is not usable speech
        let spoken = frames.filter { $0.rms > loudest * 0.0316 }
        guard spoken.count >= 8 else { return nil }
        var sum = [Float](repeating: 0, count: n / 2), one = [Float](repeating: 0, count: n / 2)
        samples.withUnsafeBufferPointer { p in
            for f in spoken {
                fft.power(p.baseAddress! + f.start, into: &one)
                vDSP_vadd(sum, 1, one, 1, &sum, 1, vDSP_Length(n / 2))
            }
        }
        var scale = 1 / Float(spoken.count)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(n / 2))
        return (Spectrum.bands(power: sum, sampleRate: sampleRate, centres: centres, fraction: 6), Double(spoken.count * hop) / sampleRate)
    }

    /// `reference` replaces the built-in target with another recording's measured tone, to make one
    /// microphone sound like another.
    static func fit(levels: [Double], seconds: Double, target: Target, strength: Double, sampleRate: Double, reference: [Double]? = nil) -> Result {
        let want = reference ?? targetCurve(target)
        // Match loudness over the middle of the voice, then smooth so the fit follows tone, not pitch.
        // The median, so one narrow bump in the voice doesn't drag the whole target with it.
        let mid = centres.indices.filter { centres[$0] >= 150 && centres[$0] <= 6000 }
        let offsets = mid.map { levels[$0] - want[$0] }.sorted()
        let offset = offsets[offsets.count / 2]
        let wanted = want.map { $0 + offset }
        var gap = zip(wanted, levels).map { $0 - $1 }
        gap = gap.indices.map { i in
            let lo = max(0, i - 1), hi = min(gap.count - 1, i + 1)
            return gap[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }.map { min(max($0, -9), 9) }

        // Matching another mic leaves the rumble filter out: the reference decides the low end.
        var bands: [Band] = reference == nil ? [Band(type: .highPass, freq: 70, gainDB: 0, q: 0.71)] : []
        func response() -> [Double] {
            let cs = bands.map { Coeffs.make($0, sampleRate: sampleRate) }
            return centres.map { f in cs.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) } }
        }
        func residual() -> [Double] { zip(gap, response()).map { $0 - $1 } }
        func mean(_ r: [Double], _ lo: Double, _ hi: Double) -> Double {
            let idx = centres.indices.filter { centres[$0] >= lo && centres[$0] <= hi }
            return idx.map { r[$0] }.reduce(0, +) / Double(max(idx.count, 1))
        }
        func clamp(_ v: Double, _ m: Double) -> Double { (min(max(v, -m), m) * 10).rounded() / 10 }

        let low = clamp(mean(residual(), 90, 200), 6)
        if abs(low) >= 0.8 { bands.append(Band(type: .lowShelf, freq: 180, gainDB: low, q: 0.71)) }
        let high = clamp(mean(residual(), 6500, 12500), 6)
        if abs(high) >= 0.8 { bands.append(Band(type: .highShelf, freq: 6000, gainDB: high, q: 0.71)) }
        for _ in 0..<(reference == nil ? 3 : 5) {
            let r = residual()
            let range = centres.indices.filter { centres[$0] >= 200 && centres[$0] <= 7000 }
            guard let peak = range.max(by: { abs(r[$0]) < abs(r[$1]) }), abs(r[peak]) >= 1.2 else { break }
            // Width: how far the bump stays above half its height, in octaves.
            var lo = peak, hi = peak
            while lo > 0, r[lo - 1] * r[peak] > 0, abs(r[lo - 1]) > abs(r[peak]) / 2 { lo -= 1 }
            while hi < r.count - 1, r[hi + 1] * r[peak] > 0, abs(r[hi + 1]) > abs(r[peak]) / 2 { hi += 1 }
            let octaves = max(Double(hi - lo + 1) / 6, 1.0 / 3)
            let q = min(max(sqrt(pow(2, octaves)) / (pow(2, octaves) - 1), 0.6), 4)
            bands.append(Band(type: .bell, freq: (centres[peak]).rounded(), gainDB: clamp(r[peak] * 0.85, 6), q: (q * 100).rounded() / 100))
        }
        let before = sqrt(gap.map { $0 * $0 }.reduce(0, +) / Double(gap.count))
        let after = sqrt(residual().map { $0 * $0 }.reduce(0, +) / Double(gap.count))
        for i in bands.indices where bands[i].type.hasGain { bands[i].gainDB = (bands[i].gainDB * strength * 10).rounded() / 10 }
        bands.sort { $0.freq < $1.freq }
        return Result(target: target, strength: strength, secondsOfSpeech: (seconds * 10).rounded() / 10, bands: bands,
                      offBeforeDB: (before * 10).rounded() / 10, offAfterDB: (after * 10).rounded() / 10,
                      centres: centres, measured: levels, wanted: wanted)
    }

    /// The first channel of an audio file, as samples.
    static func read(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
        return (Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    /// Runs samples through a set of bands, for hearing a result before using it.
    static func apply(_ bands: [Band], to samples: [Float], sampleRate: Double) -> [Float] {
        var out = samples
        for b in bands where b.on {
            let c = Coeffs.make(b, sampleRate: sampleRate)
            var z1 = 0.0, z2 = 0.0
            for n in out.indices {
                let v = Double(out[n]), y = c.b0 * v + z1
                z1 = c.b1 * v - c.a1 * y + z2
                z2 = c.b2 * v - c.a2 * y
                out[n] = Float(y)
            }
        }
        return out
    }

    static func write(_ samples: [Float], sampleRate: Double, to url: URL) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                  AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return (try? file.write(from: buffer)) != nil
    }
}
