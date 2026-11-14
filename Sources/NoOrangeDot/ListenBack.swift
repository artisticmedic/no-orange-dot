import AVFoundation
import CoreAudio
import Foundation

/// Plays the processed mic to the Mac's output, so you hear yourself as other people will.
/// It reads a short way behind the live audio. The mic and the output run on separate clocks, so
/// when the gap drifts too far it jumps back into place.
final class ListenBack {
    private var engine: AVAudioEngine?
    private var readIndex = -1
    /// Copies the newest processed samples: (ring, size, write position).
    var source: (() -> (UnsafeMutablePointer<Float>, Int, Int))?

    var running: Bool { engine != nil }

    func start(sampleRate: Double) -> Bool {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        readIndex = -1
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
    }

    private func render(_ frames: Int, _ out: UnsafeMutableAudioBufferListPointer) {
        guard let (ring, size, write) = source?(), out.count > 0, let d = out[0].mData?.assumingMemoryBound(to: Float.self), frames < size / 2 else {
            for b in out { if let m = b.mData { memset(m, 0, Int(b.mDataByteSize)) } }
            return
        }
        let mask = size - 1
        let lag = (write - readIndex) & mask
        // About 10 ms of slack behind the newest audio; resync when the clocks have drifted out of that window.
        if readIndex < 0 || lag < frames || lag > frames + 2400 { readIndex = (write - frames - 480) & mask }
        for i in 0..<frames { d[i] = ring[(readIndex + i) & mask] }
        readIndex = (readIndex + frames) & mask
    }

    /// True when sound would come out of the Mac's own speakers, where the mic would hear it and howl.
    static var outputIsBuiltInSpeakers: Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return false }
        var t = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0; size = 4
        AudioObjectGetPropertyData(dev, &t, 0, nil, &size, &transport)
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0; size = 4
        // Built-in output with no data source to ask is the speakers on current Macs; 'hdpn' is the headphone jack.
        guard AudioObjectGetPropertyData(dev, &s, 0, nil, &size, &source) == noErr else { return true }
        return source != 0x6864706E // 'hdpn'
    }
}
