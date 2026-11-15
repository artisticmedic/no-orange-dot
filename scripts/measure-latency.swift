// Measures the delay the app adds between the real microphone and the virtual one.
// Records both at once, plays a short system sound, and compares when each heard it.
// Usage: swift scripts/measure-latency.swift ["Real Mic Name"] ["Virtual Mic Name"]
import CoreAudio
import Foundation

func devices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids
}

func name(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    return (value?.takeRetainedValue() as String?) ?? ""
}

func rate(_ id: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    return value
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func seconds(_ host: UInt64) -> Double { Double(host) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }

final class Capture {
    let id: AudioDeviceID
    let rate: Double
    var start: Double?
    var samples = [Float]()
    var proc: AudioDeviceIOProcID?
    let lock = NSLock()

    init(_ id: AudioDeviceID) { self.id = id; rate = main.rate(id) }

    func run() -> Bool {
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { [unowned self] _, input, time, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = list.first, let data = buffer.mData else { return }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (4 * channels)
            let floats = data.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            if self.start == nil { self.start = seconds(time.pointee.mHostTime) }
            for i in 0..<frames { self.samples.append(floats[i * channels]) }
            self.lock.unlock()
        }
        return status == noErr && AudioDeviceStart(id, proc) == noErr
    }

    func stop() { AudioDeviceStop(id, proc); if let proc { AudioDeviceDestroyIOProcID(id, proc) } }

    /// Loudness every millisecond, on a clock shared by both captures.
    func envelope(from origin: Double, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        guard let start else { return out }
        let per = Int(rate / 1000)
        for ms in 0..<length {
            let first = Int(((origin + Double(ms) / 1000) - start) * rate)
            guard first >= 0, first + per <= samples.count else { continue }
            var sum: Float = 0
            for i in first..<(first + per) { sum += samples[i] * samples[i] }
            out[ms] = (sum / Float(per)).squareRoot()
        }
        return out
    }
}

let arguments = CommandLine.arguments
let realName = arguments.count > 1 ? arguments[1] : "MacBook Pro Microphone"
let virtualName = arguments.count > 2 ? arguments[2] : "No Orange Dot Mic"
guard let realID = devices().first(where: { name($0) == realName }),
      let virtualID = devices().first(where: { name($0) == virtualName }) else {
    print("Could not find \(realName) and \(virtualName)."); exit(1)
}

let real = Capture(realID), virtual = Capture(virtualID)
guard real.run(), virtual.run() else { print("Could not start recording."); exit(1) }

var results = [Int]()
Thread.sleep(forTimeInterval: 2)
for _ in 0..<5 {
    let began = seconds(mach_absolute_time())
    let sound = Process()
    sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    sound.arguments = ["/System/Library/Sounds/Tink.aiff"]
    try? sound.run()
    Thread.sleep(forTimeInterval: 1.2)
    real.lock.lock(); virtual.lock.lock()
    let a = real.envelope(from: began, length: 1000), b = virtual.envelope(from: began, length: 1000)
    real.lock.unlock(); virtual.lock.unlock()
    var best = 0, bestScore: Float = 0
    for lag in 0..<200 {
        var score: Float = 0
        for i in 0..<(1000 - lag) { score += a[i] * b[i + lag] }
        if score > bestScore { bestScore = score; best = lag }
    }
    let peakA = a.max() ?? 0, peakB = b.max() ?? 0
    print(String(format: "delay %3d ms   real peak %.4f   virtual peak %.4f", best, peakA, peakB))
    if peakA > 0.002, peakB > 0.0005 { results.append(best) }
}
real.stop(); virtual.stop()

if results.isEmpty { print("The sound did not reach both microphones. Is the volume up?"); exit(1) }
let sorted = results.sorted()
print("Added delay: \(sorted[sorted.count / 2]) ms (median of \(results.count), \(Int(real.rate)) Hz)")
