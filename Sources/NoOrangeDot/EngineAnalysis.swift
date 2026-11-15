import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: Live analysis

    func analyze(raw: UnsafeMutablePointer<Float>, post postRing: UnsafeMutablePointer<Float>, end: Int, rate: Double) {
        let n = analyzer.size, mask = Self.ringSize - 1
        let rawRing = raw, sampleRate = rate
        var block = [Float](repeating: 0, count: n), power = [Float](repeating: 0, count: n / 2)
        func levels(_ ring: UnsafeMutablePointer<Float>, _ previous: [Float]) -> [Float] {
            for i in 0..<n { block[i] = ring[(end - n + i) & mask] }
            block.withUnsafeBufferPointer { analyzer.power($0.baseAddress!, into: &power) }
            let now = Spectrum.bands(power: power, sampleRate: sampleRate, centres: Self.displayCentres, fraction: 12).map(Float.init)
            guard previous.count == now.count else { return now }
            // Rise quickly, fall slowly, so the shape is readable instead of flickering.
            return zip(now, previous).map { $0 > $1 ? $1 + ($0 - $1) * 0.6 : $1 + ($0 - $1) * 0.12 }
        }
        scope.spectrumRaw = levels(rawRing, scope.spectrumRaw)
        let post = levels(postRing, [])
        scope.spectrumPost = scope.spectrumPost.count == post.count ? zip(post, scope.spectrumPost).map { $0 > $1 ? $1 + ($0 - $1) * 0.6 : $1 + ($0 - $1) * 0.12 } : post

        // Spectrogram: one new column per tick, scrolling left once the image is full.
        let w = Self.historyWidth, h = post.count
        if historyColumn >= w {
            heat.withUnsafeMutableBytes { raw in
                let p = raw.baseAddress!
                for row in 0..<h { memmove(p + row * w * 4, p + row * w * 4 + 4, (w - 1) * 4) }
            }
            historyColumn = w - 1
        }
        for (i, v) in post.enumerated() {
            let t = min(max((v - Self.displayFloor) / (Self.displayCeiling - Self.displayFloor), 0), 1)
            let o = ((h - 1 - i) * w + historyColumn) * 4
            let c = Self.heat(t)
            heat[o] = c.0; heat[o + 1] = c.1; heat[o + 2] = c.2; heat[o + 3] = 255
        }
        historyColumn += 1
        let data = Data(heat) as CFData
        if let provider = CGDataProvider(data: data) {
            scope.spectrogram = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Quiet to loud: near-black, deep blue, magenta, orange, pale yellow.
    static func heat(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0.05, 0.05, 0.09), (0.16, 0.10, 0.42), (0.62, 0.16, 0.50), (0.96, 0.45, 0.22), (0.99, 0.93, 0.62)]
        let x = t * Float(stops.count - 1), i = min(Int(x), stops.count - 2), u = x - Float(i)
        let a = stops[i], b = stops[i + 1]
        return (UInt8((a.0 + (b.0 - a.0) * u) * 255), UInt8((a.1 + (b.1 - a.1) * u) * 255), UInt8((a.2 + (b.2 - a.2) * u) * 255))
    }

    // MARK: Automatic EQ

    /// Listens to the raw mic for a while, then works out an EQ. The mic is opened for the
    /// measurement and closed again afterwards unless something else needs it.
    func startMeasure(seconds: Double = 20, done: ((AutoEQ.Result?) -> Void)? = nil) {
        guard driverInstalled, ioProc != nil, !captureFlag else { done?(nil); return }
        let goal = Int(min(max(seconds, 5), 60) * sampleRate)
        if captureCapacity < goal {
            capture?.deallocate()
            capture = UnsafeMutablePointer<Float>.allocate(capacity: goal)
            captureCapacity = goal
        }
        captureCount = 0; captureGoal = goal
        autoResult = nil; autoProblem = nil; measured = nil
        measureDone = done
        monitoringBeforeMeasure = monitoring
        monitoring = true
        measureProgress = 0
        captureFlag = true
    }

    func cancelMeasure() {
        guard captureFlag else { return }
        captureFlag = false
        measureProgress = nil
        monitoring = monitoringBeforeMeasure
        measureDone?(nil); measureDone = nil
    }

    func finishMeasure() {
        captureFlag = false
        measureProgress = nil
        monitoring = monitoringBeforeMeasure
        guard let capture else { return }
        let samples = Array(UnsafeBufferPointer(start: capture, count: captureCount)), rate = sampleRate
        DispatchQueue.global(qos: .userInitiated).async {
            let m = AutoEQ.measure(samples, sampleRate: rate)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let m {
                    self.measured = (samples, m.levels, m.seconds, rate)
                    self.refit()
                } else {
                    self.autoProblem = "That was too quiet to measure. Speak at your normal level, close to the mic, for the whole time."
                }
                self.measureDone?(self.autoResult); self.measureDone = nil
            }
        }
    }

    func refit() {
        guard let m = measured else { return }
        autoResult = AutoEQ.fit(levels: m.levels, seconds: m.seconds, target: autoTarget, strength: autoStrength, sampleRate: m.sampleRate)
    }

    func useAutoEQ() {
        guard let r = autoResult else { return }
        bands = r.bands
        bypass = false
        autoResult = nil; measured = nil
    }

    func discardAutoEQ() { autoResult = nil; autoProblem = nil; measured = nil }

    /// The measured recording as a file, raw or with the suggested EQ, for listening before deciding.
    func audition(processed: Bool) -> URL? {
        guard let m = measured, let r = autoResult else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(processed ? "nod-after.wav" : "nod-before.wav")
        let samples = processed ? AutoEQ.apply(r.bands, to: m.samples, sampleRate: m.sampleRate) : m.samples
        return AutoEQ.write(samples, sampleRate: m.sampleRate, to: url) ? url : nil
    }
}
