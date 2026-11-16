import Foundation

/// Average sample level, not LUFS or a measurement of acoustic loudness.
struct VoiceLevel {
    static let referenceDB = -20.0
    static let speakingRange = -24.0 ... -16.0
    static let signalFloorDB = -50.0
    static let clippingDB = -1.0
    static let nearClippingDB = -3.0

    struct Reading: Equatable {
        var averageDB: Double
        var peakDB: Double
        static let silence = Reading(averageDB: -100, peakDB: -100)
    }

    private var meanSquare = 0.0
    private var peak = 0.0

    var reading: Reading {
        Reading(averageDB: max(-100, 10 * log10(max(meanSquare, 1e-10))),
                peakDB: max(-100, 20 * log10(max(peak, 1e-5))))
    }

    mutating func reset() { meanSquare = 0; peak = 0 }

    /// Called by one audio producer. Reading/cross-thread publication belongs to its owner.
    mutating func consume(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int, stereo: Bool, sampleRate: Double) {
        guard frames > 0, sampleRate.isFinite, sampleRate > 0 else { return }
        var sum = 0.0, largest = 0.0
        for i in 0..<frames {
            let l = left[i].isFinite ? Double(left[i]) : 0
            sum += l * l
            largest = max(largest, abs(l))
            if stereo {
                let r = right[i].isFinite ? Double(right[i]) : 0
                sum += r * r
                largest = max(largest, abs(r))
            }
        }
        let release = exp(-Double(frames) / (sampleRate * 0.4))
        let blockPower = sum / (Double(frames) * (stereo ? 2 : 1))
        meanSquare = release * meanSquare + (1 - release) * blockPower
        peak = max(largest, peak * release)
    }
}
