import AppKit
import CoreAudio
import Foundation

enum Brand {
    static let name = "Tim's Amazing No Orange Dot Microphone EQ"
    static let short = "No Orange Dot"
    static let micName = "No Orange Dot Mic"
    static let bundleID = "com.timgailey.noorangedot"
    static let micUID = "NoOrangeDot_UID"      // visible input device apps select
    static let feedUID = "NoOrangeDot_2_UID"   // hidden output device the app writes to
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func device(uid: String) -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return err == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var a = addr(sel, scope); var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
        return v
    }

    /// The preamp gain a microphone or interface exposes to the Mac, when it exposes one.
    struct Gain: Equatable { var db: Double; var min: Double; var max: Double }

    static func inputGain(_ dev: AudioDeviceID) -> Gain? {
        var a = addr(kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return nil }
        var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
        var r = addr(kAudioDevicePropertyVolumeRangeDecibels, kAudioDevicePropertyScopeInput)
        var range = AudioValueRange(); size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(dev, &r, 0, nil, &size, &range) == noErr, range.mMaximum > range.mMinimum else { return nil }
        return Gain(db: Double(v), min: range.mMinimum, max: range.mMaximum)
    }

    static func setInputGain(_ dev: AudioDeviceID, db: Double) {
        var a = addr(kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyScopeInput); var v = Float32(db)
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func sampleRate(_ dev: AudioDeviceID) -> Double {
        var a = addr(kAudioDevicePropertyNominalSampleRate); var v: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v)
        return v
    }

    static func streamCount(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreams, scope); var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size)
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func defaultInputUID() -> String? {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice); var dev = AudioDeviceID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &dev) == noErr, dev != kAudioObjectUnknown else { return nil }
        return string(dev, kAudioDevicePropertyDeviceUID)
    }

    /// The driver's box. Core Audio won't let a client rename a device, but it will rename a box,
    /// and our driver uses the box name as the mic's name.
    static func micBox() -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyBoxList); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return nil }
        var boxes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &boxes) == noErr else { return nil }
        return boxes.first { string($0, kAudioBoxPropertyBoxUID) == Brand.micUID }
    }

    static func rename(to name: String) -> Bool {
        guard let box = micBox() else { return false }
        var a = addr(kAudioObjectPropertyName); var cf = name as CFString
        return withUnsafeMutablePointer(to: &cf) { AudioObjectSetPropertyData(box, &a, 0, nil, UInt32(MemoryLayout<CFString>.size), $0) } == noErr
    }

    /// Names of other apps that are reading input from a device right now.
    struct Client: Equatable { var name: String; var pid: pid_t }

    static func inputClients(of device: AudioDeviceID) -> [Client] {
        var a = addr(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &procs) == noErr else { return [] }
        var names: [Client] = []
        for p in procs where uint32(p, kAudioProcessPropertyIsRunningInput) != 0 {
            var pid: pid_t = 0; var ps = UInt32(MemoryLayout<pid_t>.size); var pa = addr(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(p, &pa, 0, nil, &ps, &pid) == noErr, pid != getpid() else { continue }
            var da = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput); var ds: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(p, &da, 0, nil, &ds) == noErr, ds > 0 else { continue }
            var devs = [AudioDeviceID](repeating: 0, count: Int(ds) / MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(p, &da, 0, nil, &ds, &devs) == noErr, devs.contains(device) else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? processName(pid)
                ?? string(p, kAudioProcessPropertyBundleID)?.split(separator: ".").last.map(String.init)
                ?? "An app"
            if !names.contains(where: { $0.name == name }) { names.append(Client(name: name, pid: pid)) }
        }
        return names
    }

    /// The name of a process that is not a regular app, such as a command-line tool.
    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, 256) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    static func setDefaultInput(_ dev: AudioDeviceID) -> Bool {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice); var d = dev
        return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
    }

    static func setSampleRate(_ dev: AudioDeviceID, _ rate: Double) {
        var a = addr(kAudioDevicePropertyNominalSampleRate); var v = Float64(rate)
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &v)
    }

    static func inputChannels(_ dev: AudioDeviceID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    struct Input: Identifiable, Hashable { let uid: String; let name: String; var id: String { uid } }

    /// Physical and virtual devices that have at least one input stream, minus our own.
    static func inputDevices() -> [Input] {
        var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
        return ids.compactMap { id in
            guard streamCount(id, kAudioObjectPropertyScopeInput) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("NoOrangeDot"), !uid.hasPrefix(Brand.bundleID), !isPrivateAggregate(id, uid: uid) else { return nil }
            return Input(uid: uid, name: name)
        }
    }

    /// macOS builds a "CADefaultDeviceAggregate-<pid>-<n>" device for an app that plays audio, and drops it when that
    /// app quits. Each launch makes new ones, so a saved one never comes back.
    static func isTransient(_ uid: String) -> Bool { uid.hasPrefix("CADefaultDeviceAggregate") }

    /// A private aggregate belongs to the process that made it, so it is never a microphone to offer.
    static func isPrivateAggregate(_ id: AudioDeviceID, uid: String) -> Bool {
        if isTransient(uid) { return true }
        guard uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate else { return false }
        var a = addr(kAudioAggregateDevicePropertyComposition)
        var ref: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr,
              let composition = ref?.takeRetainedValue() as? [String: Any] else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }
}
