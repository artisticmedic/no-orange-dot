import Foundation
import os

enum BandType: String, Codable, CaseIterable, Identifiable {
    case highPass, lowShelf, bell, highShelf, lowPass
    var id: String { rawValue }
    var hasGain: Bool { self == .lowShelf || self == .bell || self == .highShelf }
    var label: String {
        switch self {
        case .highPass: return "High-pass"
        case .lowShelf: return "Low shelf"
        case .bell: return "Bell"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low-pass"
        }
    }
}

struct Band: Codable, Identifiable, Equatable {
    var id = UUID()   // in-memory only; not written to config.json
    var type: BandType
    var freq: Double
    var gainDB: Double
    var q: Double
    var on = true

    enum CodingKeys: String, CodingKey { case type, freq, gainDB, q, on }
    init(type: BandType, freq: Double, gainDB: Double, q: Double, on: Bool = true) {
        self.type = type; self.freq = freq; self.gainDB = gainDB; self.q = q; self.on = on
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(BandType.self, forKey: .type)
        freq = try c.decode(Double.self, forKey: .freq)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        q = try c.decodeIfPresent(Double.self, forKey: .q) ?? 0.71
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
    }
    static func == (a: Band, b: Band) -> Bool { a.type == b.type && a.freq == b.freq && a.gainDB == b.gainDB && a.q == b.q && a.on == b.on }
}

/// Normalised biquad (a0 = 1), RBJ cookbook.
struct Coeffs {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static func make(_ band: Band, sampleRate sr: Double) -> Coeffs {
        guard band.on else { return Coeffs() }
        let f = min(max(band.freq, 10), sr * 0.45)
        let w = 2 * Double.pi * f / sr, cw = cos(w), sw = sin(w)
        let q = max(band.q, 0.1)
        let alpha = sw / (2 * q)
        let A = pow(10, band.gainDB / 40)
        var b0, b1, b2, a0, a1, a2: Double
        switch band.type {
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .bell:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s
        }
        return Coeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    func magnitudeDB(at f: Double, sampleRate sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10(max((nr * nr + ni * ni) / (dr * dr + di * di), 1e-12))
    }
}

struct Dynamics: Codable, Equatable {
    var gateOn = false
    var gateThresholdDB = -50.0
    var gateRangeDB = -30.0      // how far the gate turns the mic down when closed
    var gateHoldMs = 120.0       // how long it stays open after the voice drops below the threshold
    var gateReleaseMs = 180.0    // how slowly it closes
    var compOn = false
    var compThresholdDB = -18.0
    var compRatio = 3.0
    var compAttackMs = 8.0
    var compReleaseMs = 150.0
    var compMakeupDB = 0.0
    var limiterOn = false
    var limiterCeilingDB = -1.0   // nothing leaves louder than this

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Dynamics()
        gateOn = try c.decodeIfPresent(Bool.self, forKey: .gateOn) ?? d.gateOn
        gateThresholdDB = try c.decodeIfPresent(Double.self, forKey: .gateThresholdDB) ?? d.gateThresholdDB
        gateRangeDB = try c.decodeIfPresent(Double.self, forKey: .gateRangeDB) ?? d.gateRangeDB
        gateHoldMs = try c.decodeIfPresent(Double.self, forKey: .gateHoldMs) ?? d.gateHoldMs
        gateReleaseMs = try c.decodeIfPresent(Double.self, forKey: .gateReleaseMs) ?? d.gateReleaseMs
        compOn = try c.decodeIfPresent(Bool.self, forKey: .compOn) ?? d.compOn
        compThresholdDB = try c.decodeIfPresent(Double.self, forKey: .compThresholdDB) ?? d.compThresholdDB
        compRatio = try c.decodeIfPresent(Double.self, forKey: .compRatio) ?? d.compRatio
        compAttackMs = try c.decodeIfPresent(Double.self, forKey: .compAttackMs) ?? d.compAttackMs
        compReleaseMs = try c.decodeIfPresent(Double.self, forKey: .compReleaseMs) ?? d.compReleaseMs
        compMakeupDB = try c.decodeIfPresent(Double.self, forKey: .compMakeupDB) ?? d.compMakeupDB
        limiterOn = try c.decodeIfPresent(Bool.self, forKey: .limiterOn) ?? d.limiterOn
        limiterCeilingDB = try c.decodeIfPresent(Double.self, forKey: .limiterCeilingDB) ?? d.limiterCeilingDB
    }
}

/// Realtime chain: EQ, then noise gate, then compressor, then output gain, then the limiter. Stereo, with linked dynamics.
/// `set` runs on the main thread; `process` runs on the audio thread and never blocks.
final class DSPChain {
    static let maxBands = 8
    private struct Params {
        var count = 0
        var gain: Float = 1
        var dyn = Dynamics()
        var sampleRate = 48000.0
    }
    private let live = UnsafeMutablePointer<Double>.allocate(capacity: maxBands * 5)
    private let pending = UnsafeMutablePointer<Double>.allocate(capacity: maxBands * 5)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxBands * 4) // z1, z2 per band per channel
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var p = Params(), pendingP = Params(), dirty = false

    // Dynamics state and per-sample coefficients, audio thread only.
    private var env = 0.0, gateGain = 1.0, gateHold = 0, compGR = 0.0
    private var envRel = 0.0, gateOpen = 0.0, gateClose = 0.0, gateHoldSamples = 0, gateFloor = 0.0, gateThresh = 0.0
    private var compAtt = 0.0, compRel = 0.0, makeup = 1.0
    /// Largest gain reduction (dB, positive) since the UI last read it.
    var reductionMeter: Float = 0
    private var limGain: Float = 1, limRel: Float = 0, limCeil: Float = 1
    /// Largest amount (dB, positive) the limiter has pulled a peak down since the UI last read it.
    var limiterMeter: Float = 0

    init() {
        live.initialize(repeating: 0, count: Self.maxBands * 5)
        pending.initialize(repeating: 0, count: Self.maxBands * 5)
        state.initialize(repeating: 0, count: Self.maxBands * 4)
        lock.initialize(to: os_unfair_lock())
    }

    func set(bands: [Band], dynamics: Dynamics, sampleRate: Double, outputGainDB: Double, bypass: Bool) {
        let active = bypass ? [] : Array(bands.filter(\.on).prefix(Self.maxBands))
        os_unfair_lock_lock(lock)
        for (i, b) in active.enumerated() {
            let c = Coeffs.make(b, sampleRate: sampleRate)
            pending[i * 5] = c.b0; pending[i * 5 + 1] = c.b1; pending[i * 5 + 2] = c.b2
            pending[i * 5 + 3] = c.a1; pending[i * 5 + 4] = c.a2
        }
        var d = dynamics
        if bypass { d.gateOn = false; d.compOn = false }
        pendingP = Params(count: active.count, gain: Float(pow(10, outputGainDB / 20)), dyn: d, sampleRate: sampleRate)
        dirty = true
        os_unfair_lock_unlock(lock)
    }

    private func adopt() {
        memcpy(live, pending, MemoryLayout<Double>.size * Self.maxBands * 5)
        if pendingP.count != p.count { memset(state, 0, MemoryLayout<Double>.size * Self.maxBands * 4) }
        p = pendingP
        let sr = p.sampleRate
        func coef(_ ms: Double) -> Double { exp(-1 / (max(ms, 0.05) * 0.001 * sr)) }
        envRel = coef(60)
        gateOpen = coef(3); gateClose = coef(max(p.dyn.gateReleaseMs, 10)); gateHoldSamples = Int(max(p.dyn.gateHoldMs, 0) / 1000 * sr)
        gateFloor = pow(10, p.dyn.gateRangeDB / 20); gateThresh = pow(10, p.dyn.gateThresholdDB / 20)
        compAtt = coef(p.dyn.compAttackMs); compRel = coef(p.dyn.compReleaseMs)
        makeup = pow(10, p.dyn.compMakeupDB / 20)
        if !p.dyn.gateOn { gateGain = 1 }
        if !p.dyn.compOn { compGR = 0 }
        limRel = Float(coef(80)); limCeil = Float(pow(10, min(p.dyn.limiterCeilingDB, 0) / 20))
        if !p.dyn.limiterOn { limGain = 1 }
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int, stereo: Bool) {
        if os_unfair_lock_trylock(lock) {
            if dirty { adopt(); dirty = false }
            os_unfair_lock_unlock(lock)
        }
        for ch in 0..<(stereo ? 2 : 1) {
            let x = ch == 0 ? l : r
            for b in 0..<p.count {
                let b0 = live[b * 5], b1 = live[b * 5 + 1], b2 = live[b * 5 + 2], a1 = live[b * 5 + 3], a2 = live[b * 5 + 4]
                var z1 = state[b * 4 + ch * 2], z2 = state[b * 4 + ch * 2 + 1]
                for n in 0..<frames {
                    let v = Double(x[n])
                    let y = b0 * v + z1
                    z1 = b1 * v - a1 * y + z2
                    z2 = b2 * v - a2 * y
                    x[n] = Float(y)
                }
                if abs(z1) < 1e-30 { z1 = 0 }; if abs(z2) < 1e-30 { z2 = 0 }
                state[b * 4 + ch * 2] = z1; state[b * 4 + ch * 2 + 1] = z2
            }
        }

        let gateOn = p.dyn.gateOn, compOn = p.dyn.compOn
        if gateOn || compOn {
            let thr = p.dyn.compThresholdDB, slope = 1 - 1 / max(p.dyn.compRatio, 1)
            var maxGR = Double(reductionMeter)
            for n in 0..<frames {
                let a = stereo ? max(abs(Double(l[n])), abs(Double(r[n]))) : abs(Double(l[n]))
                env = a > env ? a : envRel * env + (1 - envRel) * a
                var g = 1.0
                if gateOn {
                    if env >= gateThresh { gateHold = gateHoldSamples } else if gateHold > 0 { gateHold -= 1 }
                    let target = gateHold > 0 ? 1.0 : gateFloor
                    let c = target > gateGain ? gateOpen : gateClose
                    gateGain = c * gateGain + (1 - c) * target
                    g *= gateGain
                }
                if compOn {
                    let over = 20 * log10(max(env, 1e-9)) - thr
                    let target = over > 0 ? over * slope : 0
                    let c = target > compGR ? compAtt : compRel
                    compGR = c * compGR + (1 - c) * target
                    if compGR > maxGR { maxGR = compGR }
                    g *= pow(10, -compGR / 20) * makeup
                }
                let gf = Float(g)
                l[n] *= gf
                if stereo { r[n] *= gf }
            }
            reductionMeter = Float(maxGR)
        }

        let g = p.gain
        if g != 1 {
            for n in 0..<frames { l[n] *= g }
            if stereo { for n in 0..<frames { r[n] *= g } }
        }

        // Limiter: the gain drops at once to keep a peak under the ceiling, then eases back.
        if p.dyn.limiterOn {
            var lowest = limGain
            for n in 0..<frames {
                let peak = stereo ? max(abs(l[n]), abs(r[n])) : abs(l[n])
                let needed: Float = peak > limCeil ? limCeil / peak : 1
                limGain = needed < limGain ? needed : limRel * limGain + (1 - limRel) * needed
                if limGain < lowest { lowest = limGain }
                l[n] *= limGain
                if stereo { r[n] *= limGain }
            }
            let db = -20 * log10(max(lowest, 1e-6))
            if db > limiterMeter { limiterMeter = db }
        }
    }
}

enum Presets {
    static let flat: [Band] = [
        Band(type: .highPass, freq: 50, gainDB: 0, q: 0.71, on: false),
        Band(type: .lowShelf, freq: 150, gainDB: 0, q: 0.71),
        Band(type: .bell, freq: 480, gainDB: 0, q: 0.7),
        Band(type: .bell, freq: 2500, gainDB: 0, q: 0.9),
        Band(type: .highShelf, freq: 6000, gainDB: 0, q: 0.71),
    ]
    /// A gentle spoken-voice curve: rumble filter, low-end warmth, less boxiness, a little air.
    static let warm: [Band] = [
        Band(type: .highPass, freq: 50, gainDB: 0, q: 0.71),
        Band(type: .lowShelf, freq: 150, gainDB: 2.9, q: 0.71),
        Band(type: .bell, freq: 480, gainDB: -3.0, q: 0.5),
        Band(type: .bell, freq: 2500, gainDB: 0, q: 0.9),
        Band(type: .highShelf, freq: 4000, gainDB: 2.8, q: 0.71),
    ]
}
