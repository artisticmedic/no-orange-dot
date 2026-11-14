import XCTest
@testable import NoOrangeDot

final class DSPTests: XCTestCase {
    let sr = 48000.0

    private func sine(_ freq: Double, db: Double, seconds: Double) -> [Float] {
        let a = pow(10, db / 20)
        return (0..<Int(seconds * sr)).map { Float(a * sin(2 * .pi * freq * Double($0) / sr)) }
    }

    private func run(_ chain: DSPChain, _ input: [Float], block: Int = 512, stereo: Bool = false) -> [Float] {
        var l = input, r = input
        var at = 0
        while at < l.count {
            let n = min(block, l.count - at)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    chain.process(lp.baseAddress! + at, rp.baseAddress! + at, frames: n, stereo: stereo)
                }
            }
            at += n
        }
        return l
    }

    private func peakDB(_ x: ArraySlice<Float>) -> Double { 20 * log10(Double(x.map(abs).max() ?? 0) + 1e-12) }

    /// Level of a steady sine from its RMS, which does not depend on where the samples land on the wave.
    private func sineDB(_ x: ArraySlice<Float>) -> Double {
        let ms = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        return 10 * log10(2 * ms + 1e-24)
    }

    private func chain(bands: [Band] = [], _ edit: (inout Dynamics) -> Void = { _ in }, gain: Double = 0, bypass: Bool = false) -> DSPChain {
        var d = Dynamics(); edit(&d)
        let c = DSPChain()
        c.set(bands: bands, dynamics: d, sampleRate: sr, outputGainDB: gain, bypass: bypass)
        return c
    }

    func testBellGainAtCentre() {
        let c = Coeffs.make(Band(type: .bell, freq: 1000, gainDB: 6, q: 1), sampleRate: sr)
        XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: sr), 6, accuracy: 0.01)
        XCTAssertEqual(c.magnitudeDB(at: 20, sampleRate: sr), 0, accuracy: 0.1)
    }

    func testHighPassIsThreeDBDownAtCutoff() {
        let c = Coeffs.make(Band(type: .highPass, freq: 100, gainDB: 0, q: 0.7071), sampleRate: sr)
        XCTAssertEqual(c.magnitudeDB(at: 100, sampleRate: sr), -3.01, accuracy: 0.05)
        XCTAssertLessThan(c.magnitudeDB(at: 25, sampleRate: sr), -20)
    }

    func testShelvesReachTheirGain() {
        let low = Coeffs.make(Band(type: .lowShelf, freq: 150, gainDB: 4, q: 0.71), sampleRate: sr)
        XCTAssertEqual(low.magnitudeDB(at: 20, sampleRate: sr), 4, accuracy: 0.2)
        XCTAssertEqual(low.magnitudeDB(at: 10000, sampleRate: sr), 0, accuracy: 0.1)
        let high = Coeffs.make(Band(type: .highShelf, freq: 4000, gainDB: -5, q: 0.71), sampleRate: sr)
        XCTAssertEqual(high.magnitudeDB(at: 20000, sampleRate: sr), -5, accuracy: 0.2)
        XCTAssertEqual(high.magnitudeDB(at: 100, sampleRate: sr), 0, accuracy: 0.1)
    }

    func testBandThatIsOffIsFlat() {
        let c = Coeffs.make(Band(type: .bell, freq: 1000, gainDB: 12, q: 1, on: false), sampleRate: sr)
        XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: sr), 0, accuracy: 1e-9)
    }

    func testExtremeBandsStayStable() {
        for sr in [44100.0, 48000, 96000] {
            for band in [Band(type: .bell, freq: 5, gainDB: 24, q: 0.01), Band(type: .highShelf, freq: 90000, gainDB: -24, q: 30),
                         Band(type: .lowPass, freq: 20000, gainDB: 0, q: 10)] {
                let c = Coeffs.make(band, sampleRate: sr)
                // Poles inside the unit circle.
                XCTAssertLessThan(abs(c.a2), 1)
                XCTAssertLessThan(abs(c.a1), 1 + c.a2)
            }
        }
    }

    func testProcessedAudioMatchesTheDrawnCurve() {
        let bands = Presets.warm
        for f in [60.0, 150, 480, 2500, 8000] {
            let out = run(chain(bands: bands), sine(f, db: -20, seconds: 1))
            let expected = bands.reduce(-20.0) { $0 + Coeffs.make($1, sampleRate: sr).magnitudeDB(at: f, sampleRate: sr) }
            XCTAssertEqual(sineDB(out[24000...]), expected, accuracy: 0.05, "\(f) Hz")
        }
    }

    func testBypassPassesAudioUnchanged() {
        let input = sine(440, db: -12, seconds: 0.2)
        let out = run(chain(bands: Presets.warm, { $0.gateOn = true; $0.compOn = true }, bypass: true), input)
        XCTAssertEqual(out, input)
    }

    func testNoBandsNoDynamicsIsTransparent() {
        let input = sine(440, db: -12, seconds: 0.2)
        XCTAssertEqual(run(chain(), input), input)
    }

    func testOutputGain() {
        let out = run(chain(gain: 6), sine(440, db: -20, seconds: 0.2))
        XCTAssertEqual(peakDB(out[...]), -14, accuracy: 0.05)
    }

    func testBlockSizeDoesNotChangeTheSound() {
        let input = sine(300, db: -6, seconds: 0.5)
        let edit: (inout Dynamics) -> Void = { $0.gateOn = true; $0.compOn = true; $0.limiterOn = true }
        let a = run(chain(bands: Presets.warm, edit), input, block: 64)
        let b = run(chain(bands: Presets.warm, edit), input, block: 1024)
        XCTAssertEqual(a, b)
    }

    func testGateClosesOnQuietAndOpensOnLoud() {
        let edit: (inout Dynamics) -> Void = { $0.gateOn = true; $0.gateThresholdDB = -40; $0.gateRangeDB = -30 }
        let quiet = run(chain(edit), sine(440, db: -60, seconds: 2))
        XCTAssertEqual(peakDB(quiet[72000...]), -90, accuracy: 0.5)
        let loud = run(chain(edit), sine(440, db: -20, seconds: 1))
        XCTAssertEqual(peakDB(loud[24000...]), -20, accuracy: 0.1)
    }

    func testGateHoldsOpenAfterSpeechStops() {
        let c = chain { $0.gateOn = true; $0.gateThresholdDB = -40; $0.gateRangeDB = -30; $0.gateHoldMs = 300; $0.gateReleaseMs = 50 }
        let out = run(c, sine(440, db: -20, seconds: 0.5) + sine(440, db: -60, seconds: 1.5))
        // 100 ms after the loud part ends the gate is still open; a second later it is closed.
        XCTAssertEqual(peakDB(out[(24000 + 4800)..<(24000 + 9600)]), -60, accuracy: 0.5)
        XCTAssertEqual(peakDB(out[84000...]), -90, accuracy: 0.5)
    }

    func testCompressorReducesByTheRatio() {
        let c = chain { $0.compOn = true; $0.compThresholdDB = -18; $0.compRatio = 3 }
        let out = run(c, sine(1000, db: -6, seconds: 2))
        // 12 dB over at 3:1 leaves 4 dB over.
        XCTAssertEqual(peakDB(out[72000...]), -14, accuracy: 0.5)
        XCTAssertEqual(Double(c.reductionMeter), 8, accuracy: 0.5)
    }

    func testCompressorLeavesQuietAudioAlone() {
        let input = sine(1000, db: -30, seconds: 0.5)
        let out = run(chain { $0.compOn = true; $0.compThresholdDB = -18 }, input)
        XCTAssertEqual(peakDB(out[...]), -30, accuracy: 0.01)
    }

    func testLimiterNeverPassesTheCeiling() {
        let c = chain({ $0.limiterOn = true; $0.limiterCeilingDB = -6 }, gain: 12)
        var input = sine(200, db: -3, seconds: 0.5)
        for i in stride(from: 1000, to: input.count, by: 3001) { input[i] = 1 } // clicks
        let out = run(c, input)
        XCTAssertLessThanOrEqual(peakDB(out[...]), -6 + 0.001)
        XCTAssertGreaterThan(c.limiterMeter, 10)
    }

    func testLimiterLeavesAudioUnderTheCeilingAlone() {
        let input = sine(200, db: -12, seconds: 0.2)
        XCTAssertEqual(run(chain { $0.limiterOn = true; $0.limiterCeilingDB = -1 }, input), input)
    }

    func testStereoDynamicsAreLinked() {
        let c = chain { $0.limiterOn = true; $0.limiterCeilingDB = -12 }
        var l = sine(200, db: -3, seconds: 0.2), r = sine(200, db: -30, seconds: 0.2)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            c.process(lp.baseAddress!, rp.baseAddress!, frames: lp.count, stereo: true)
        } }
        // The quiet side is turned down with the loud side, so the image does not shift.
        XCTAssertEqual(peakDB(l[4800...]) - peakDB(r[4800...]), 27, accuracy: 0.5)
    }

    func testSilenceStaysSilentAndFinite() {
        let c = chain(bands: Presets.warm) { $0.gateOn = true; $0.compOn = true; $0.limiterOn = true }
        let out = run(c, [Float](repeating: 0, count: 48000))
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
        let loud = run(c, [Float](repeating: 0, count: 100) + [Float.greatestFiniteMagnitude / 4] + [Float](repeating: 0, count: 4800))
        XCTAssertTrue(loud.allSatisfy(\.isFinite))
    }
}
