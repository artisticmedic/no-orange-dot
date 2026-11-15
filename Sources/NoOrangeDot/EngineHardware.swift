import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: Listen back

    func applyListenBack() {
        if listenBack {
            if ListenBack.outputIsBuiltInSpeakers {
                error = "Listen back needs headphones. Through the Mac's speakers the mic would hear itself and howl."
                listenBack = false
                return
            }
            listener.source = { [unowned self] in (self.postRing, Self.ringSize, self.ringIndex) }
            evaluate()
            if !listener.start(sampleRate: sampleRate) { error = "Couldn't start listen back."; listenBack = false }
        } else {
            listener.stop()
            evaluate()
        }
        if listenBack, error?.hasPrefix("Listen back") == true { error = nil }
    }

    /// The Mac's output changed. Stop rather than risk the speakers; start again on the new output otherwise.
    func outputChanged() {
        guard listenBack else { return }
        listenBack = false
        if !ListenBack.outputIsBuiltInSpeakers { listenBack = true }
    }

    // MARK: Hardware gain

    /// Reads the gain, and when it is locked, puts it back if something else has moved it.
    func refreshMicGain() {
        guard let dev = HAL.device(uid: inputUID) else { if micGain != nil { micGain = nil }; return }
        var now = HAL.inputGain(dev)
        if let lock = gainLockDB, let g = now, abs(g.db - lock) > 0.05 {
            HAL.setInputGain(dev, db: lock)
            now = HAL.inputGain(dev)
            // Hardware gain moves in steps. If it can't land on the locked value, hold the step it did land on.
            if let landed = now?.db, abs(landed - lock) > 0.05 { gainLockDB = landed }
        }
        if now != micGain { micGain = now }
    }

    /// A change made here. While the gain is locked, this moves the lock with it.
    func setMicGain(_ db: Double) {
        guard let dev = HAL.device(uid: inputUID), let g = micGain else { return }
        HAL.setInputGain(dev, db: min(max(db, g.min), g.max))
        if gainLockDB != nil, let landed = HAL.inputGain(dev)?.db { gainLockDB = landed }
        refreshMicGain()
    }

    func setGainLock(_ on: Bool) {
        refreshMicGain()
        gainLockDB = on ? micGain?.db : nil
    }
}
