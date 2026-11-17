import AVFoundation
import CoreAudio
import Foundation

/// Plays the processed mic to the Mac's output, so you hear yourself as other people will.
/// It reads a short way behind the live audio. The mic and the output run on separate clocks, so
/// when the gap drifts too far it jumps back into place.
final class ListenBack {
    private var engine: AVAudioEngine?
    private var reader = ListenBackReader()
    /// Copies the newest processed samples: (ring, size, write position).
    var source: (() -> (UnsafeMutablePointer<Float>, Int, Int))?

    var running: Bool { engine != nil }

    func start(sampleRate: Double) -> Bool {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        reader = ListenBackReader(sampleRate: sampleRate)
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
        reader = ListenBackReader()
    }

    private func render(_ frames: Int, _ out: UnsafeMutableAudioBufferListPointer) {
        for b in out { if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) } }
        guard let (ring, size, write) = source?(), out.count > 0,
              let output = out[0].mData?.assumingMemoryBound(to: Float.self),
              frames <= Int(out[0].mDataByteSize) / 4 else { return }
        reader.copy(ring, size: size, write: write, frames: frames, into: output)
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

/// Underflow waits for fresh samples instead of replaying the last block.
struct ListenBackReader {
    private var readIndex = -1
    private let slack: Int
    private let drift: Int

    init(sampleRate: Double = 48000) {
        slack = Int(sampleRate * 0.01)
        drift = Int(sampleRate * 0.05)
    }

    mutating func copy(_ ring: UnsafePointer<Float>, size: Int, write: Int, frames: Int, into output: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        memset(output, 0, frames * 4)
        guard size > 0, size & (size - 1) == 0, frames < size / 2 else { return }
        let mask = size - 1
        var lag = (write - readIndex) & mask
        if readIndex < 0 || lag > frames + drift {
            readIndex = (write - frames - slack) & mask
            lag = (write - readIndex) & mask
        }
        guard lag >= frames else { return }
        for i in 0..<frames { output[i] = ring[(readIndex + i) & mask] }
        readIndex = (readIndex + frames) & mask
    }
}
