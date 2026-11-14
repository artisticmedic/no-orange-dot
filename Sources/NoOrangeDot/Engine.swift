import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

/// Opens the real mic only while something reads the virtual mic (or while recording),
/// runs the processing chain, and writes the result into the hidden feed device.
final class Engine: ObservableObject {
    @Published var driverInstalled = false
    @Published var clientsActive = false
    @Published var running = false
    @Published var recording = false
    @Published var level: Float = 0
    @Published var reductionDB: Float = 0
    @Published var limiterDB: Float = 0
    @Published var muteShortcut = "" { didSet { if muteShortcut != oldValue { changed() } } }
    @Published var recordShortcut = "" { didSet { if recordShortcut != oldValue { changed() } } }
    @Published var lastWakeMs: Double?
    @Published var error: String?
    @Published var inputs: [HAL.Input] = []
    @Published var lastRecording: URL?
    @Published var stereoInput = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published var muted: Bool { didSet { mutedFlag = muted; evaluate(); changed() } }
    @Published var inputUID: String {
        didSet {
            guard inputUID != oldValue else { return }
            if !fallingBack { returnTo = nil }
            switchProfile(from: oldValue); rebuild(); changed()
        }
    }
    /// The chosen microphone when it has been unplugged and another stands in. Plugging it back in returns to it.
    private var returnTo: String? { didSet { if returnTo != oldValue { changed() } } }
    private var fallingBack = false
    private var builtRate = 0.0
    /// Every microphone's saved sound. The one in use is mirrored in `bands`, `dynamics`, `bypass` and `outputGainDB`.
    private var mics: [String: MicProfile] = [:]
    @Published var bands: [Band] { didSet { noteHistory(oldValue); pushDSP(); changed() } }
    @Published var dynamics: Dynamics { didSet { pushDSP(); changed() } }
    @Published var bypass: Bool { didSet { pushDSP(); changed() } }
    @Published var outputGainDB: Double { didSet { pushDSP(); changed() } }
    /// Saved sounds, shared by every microphone.
    @Published var presets: [SoundPreset] = [] { didSet { if presets != oldValue { changed() } } }
    @Published var configProblem: String?
    /// Curves this app has replaced, newest first, so any change to the EQ can be taken back.
    @Published var history: [EQSnapshot] = EQSnapshot.load()
    /// The real mic's own preamp gain, when the hardware lets the Mac set it.
    @Published var micGain: HAL.Gain?
    /// Hear yourself: the processed mic played to the Mac's output. Off at every launch.
    @Published var listenBack = false { didSet { if listenBack != oldValue { applyListenBack() } } }
    private let listener = ListenBack()
    @Published var gainLockDB: Double? { didSet { if gainLockDB != oldValue { changed(); refreshMicGain() } } }
    private var historyBefore: [Band]?
    private var historyWork: DispatchWorkItem?
    private var historyUID = ""
    @Published var icon: String { didSet { changed() } }
    @Published var appIcon = "paint" { didSet { if appIcon != oldValue { changed() } } }
    @Published var showInDock = false { didSet { if showInDock != oldValue { changed() } } }
    @Published var autoUpdate = true { didSet { if autoUpdate != oldValue { changed() } } }
    @Published var updateFeed = "" { didSet { if updateFeed != oldValue { changed() } } }
    @Published var recordingsFolder: String { didSet { if recordingsFolder != oldValue { changed(); refreshRecordings() } } }
    @Published var recordings: [Recording] = []
    /// The name the user wants apps to show for the virtual mic. Empty means the built-in name.
    @Published var micName: String { didSet { if micName != oldValue { applyMicName(); changed() } } }
    /// The name the virtual mic has right now.
    @Published var micDisplayName = Brand.micName
    @Published var canRenameMic = false
    /// True while the Mac's own input setting points at the virtual mic.
    @Published var isSystemMicrophone = false

    // Live analysis, for the spectrum, the spectrogram and automatic EQ. All of it needs the mic open,
    // so it only runs while `monitoring` is on, and the editor turns that off when it closes.
    @Published var monitoring = false { didSet { evaluate(); if !monitoring { spectrumPost = []; spectrumRaw = []; spectrogram = nil; historyColumn = 0 } } }
    @Published var spectrumPost: [Float] = []   // dB per display band, after the EQ
    @Published var spectrumRaw: [Float] = []    // dB per display band, straight from the mic
    @Published var spectrogram: CGImage?
    // Replaying a raw take through the EQ, to hear a change on the same words.
    @Published var auditioning: URL?
    @Published var auditionProgress = 0.0
    @Published var auditionLoop = true { didSet { player.loop = auditionLoop } }
    private let player = AuditionPlayer()

    @Published var measureProgress: Double?     // 0...1 while automatic EQ is listening, otherwise nil
    @Published var autoResult: AutoEQ.Result?
    @Published var autoProblem: String?
    @Published var autoTarget: AutoEQ.Target = .warm { didSet { refit() } }
    @Published var autoStrength = 1.0 { didSet { refit() } }

    /// Twelfth-octave centres from 40 Hz to about 15 kHz, for drawing.
    static let displayCentres: [Double] = (0..<104).map { 40 * pow(2, Double($0) / 12) }
    static let displayFloor: Float = -100, displayCeiling: Float = -15
    private static let ringSize = 8192
    private let rawRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let postRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private var ringIndex = 0
    private let analyzer = Spectrum(size: 4096)
    private static let historyWidth = 180
    private var heat = [UInt8](repeating: 0, count: historyWidth * 104 * 4)
    private var historyColumn = 0
    private var capture: UnsafeMutablePointer<Float>?
    private var captureCapacity = 0, captureCount = 0, captureGoal = 0
    private var captureFlag = false
    private var measured: (samples: [Float], levels: [Double], seconds: Double, sampleRate: Double)?
    private var measureDone: ((AutoEQ.Result?) -> Void)?
    private var monitoringBeforeMeasure = false

    private var applying = false
    private var saveWork: DispatchWorkItem?
    private var configStamp: Date?
    private var lastStatus = Status()
    private var ticks = 0

    private(set) var sampleRate = 48000.0
    private let dsp = DSPChain()
    private var micDevice: AudioDeviceID?
    private var aggregate: AudioDeviceID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var listenerDevice: AudioDeviceID?
    private var renameTried: String?
    private var meterTimer: Timer?
    private var deviceSignature = ""

    // Touched from the audio thread. Plain stores; no locks, no allocation.
    private static let maxFrames = 16384
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
    private var mutedFlag = false
    private var stereoFlag = false
    private var recordFlag = false
    private var recordFile: ExtAudioFileRef?
    private var recordRawFile: ExtAudioFileRef?
    private let rawLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let rawRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private var peak: Float = 0
    private var wakeRequestedAt: UInt64 = 0
    private var firstCallbackAt: UInt64 = 0

    init() {
        var s = Settings()
        switch Settings.load() {
        case .ok(let loaded): s = loaded
        case .invalid(let why): configProblem = why
        case .missing: s.save()
        }
        configStamp = Settings.modified()
        muted = s.muted
        inputUID = s.inputUID
        mics = s.mics
        let p = s.active
        bypass = !p.equalizer
        outputGainDB = p.outputGainDB
        gainLockDB = p.gainLockDB
        bands = p.bands
        dynamics = p.dynamics
        icon = s.icon
        appIcon = s.appIcon
        showInDock = s.showInDock
        autoUpdate = s.autoUpdate
        updateFeed = s.updateFeed
        presets = s.presets
        returnTo = s.returnToUID.isEmpty ? nil : s.returnToUID
        historyUID = s.inputUID
        recordingsFolder = s.recordingsFolder
        muteShortcut = s.muteShortcut
        recordShortcut = s.recordShortcut
        micName = s.micName
        mutedFlag = muted
        left.initialize(repeating: 0, count: Self.maxFrames)
        right.initialize(repeating: 0, count: Self.maxFrames)
        interleaved.initialize(repeating: 0, count: Self.maxFrames * 2)
        rawRing.initialize(repeating: 0, count: Self.ringSize)
        postRing.initialize(repeating: 0, count: Self.ringSize)

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            DispatchQueue.main.async { if !ok { self?.error = "Microphone access is off. Allow \(Brand.short) in System Settings › Privacy & Security › Microphone." } }
        }
        var a = HAL.addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(HAL.system, &a, .main) { [weak self] _, _ in self?.devicesChanged() }
        var d = HAL.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(HAL.system, &d, .main) { [weak self] _, _ in self?.refreshSystemMicrophone() }
        var o = HAL.addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(HAL.system, &o, .main) { [weak self] _, _ in self?.outputChanged() }
        // Core Audio restarts when a driver is installed. Every device ID and listener we hold dies with it.
        var r = HAL.addr(kAudioHardwarePropertyServiceRestarted)
        AudioObjectAddPropertyListenerBlock(HAL.system, &r, .main) { [weak self] _, _ in self?.coreAudioRestarted() }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        // USB microphones can come back from sleep as new devices, or at another rate.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.rebuild() }
        }
        rebuild()
    }

    // MARK: Setup

    /// Creating our own private aggregate also fires the device-list listener, so only rebuild when
    /// the real inputs or the driver actually changed. Otherwise the engine tears itself down in a loop.
    private func currentSignature() -> String {
        let driver = HAL.device(uid: Brand.micUID) != nil && HAL.device(uid: Brand.feedUID) != nil
        return HAL.inputDevices().map(\.uid).sorted().joined(separator: "|") + (driver ? "#driver" : "")
    }

    private func devicesChanged() {
        if currentSignature() != deviceSignature { rebuild() }
    }

    private func coreAudioRestarted() {
        listenerDevice = nil
        renameTried = nil
        ioProc = nil
        aggregate = kAudioObjectUnknown
        running = false
        rebuild()
        // Devices come back over a second or two; the driver may not be listed on the first pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.listenerDevice = nil
            self.rebuild()
            self.clientsChanged()
        }
    }

    /// Rebuilds the private aggregate (real mic in, feed out). Creating it does not open the mic; only start() does.
    func rebuild() {
        stopRecording()
        stop()
        teardown()
        deviceSignature = currentSignature()
        inputs = HAL.inputDevices()
        if let back = returnTo, back != inputUID, inputs.contains(where: { $0.uid == back }) {
            fallingBack = true; defer { fallingBack = false }
            returnTo = nil; inputUID = back; return // didSet re-enters rebuild
        }
        if inputUID.isEmpty || !inputs.contains(where: { $0.uid == inputUID }) {
            let preferred = HAL.defaultInputUID()
            let pick = inputs.first(where: { $0.uid == preferred }) ?? inputs.first
            if let pick, pick.uid != inputUID {
                fallingBack = true; defer { fallingBack = false }
                if !inputUID.isEmpty { returnTo = returnTo ?? inputUID }
                inputUID = pick.uid; return // didSet re-enters rebuild
            }
        }
        micDevice = HAL.device(uid: Brand.micUID)
        let feed = HAL.device(uid: Brand.feedUID)
        driverInstalled = micDevice != nil && feed != nil
        guard driverInstalled, let mic = micDevice, let feed else { clientsActive = false; return }

        if listenerDevice != mic {
            var a = HAL.addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectAddPropertyListenerBlock(mic, &a, .main) { [weak self] _, _ in self?.clientsChanged() }
            listenerDevice = mic
        }
        guard let source = HAL.device(uid: inputUID) else { clientsChanged(); return }

        // Run the virtual mic at the real mic's rate so nothing is resampled on the way through.
        let sourceRate = HAL.sampleRate(source)
        builtRate = sourceRate
        if sourceRate > 0, HAL.sampleRate(feed) != sourceRate { HAL.setSampleRate(feed, sourceRate) }
        stereoInput = HAL.inputChannels(source) == 2
        stereoFlag = stereoInput

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Brand.short) Engine",
            kAudioAggregateDeviceUIDKey: "\(Brand.bundleID).engine.\(getpid())",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: inputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: inputUID],
                [kAudioSubDeviceUIDKey: Brand.feedUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var agg: AudioDeviceID = kAudioObjectUnknown
        let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard err == noErr else { error = "Couldn't set up the audio engine (error \(err))."; return }
        aggregate = agg
        sampleRate = HAL.sampleRate(agg) > 0 ? HAL.sampleRate(agg) : 48000
        pushDSP()

        var proc: AudioDeviceIOProcID?
        let perr = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [unowned self] _, input, _, output, _ in
            self.render(input, output)
        }
        guard perr == noErr, let proc else { error = "Couldn't attach to the audio engine (error \(perr))."; return }
        ioProc = proc
        error = nil
        applyMicName()
        refreshSystemMicrophone()
        clientsChanged()
    }

    private func teardown() {
        if let p = ioProc, aggregate != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggregate, p) }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = kAudioObjectUnknown
    }

    func shutdown() { stopRecording(); stop(); teardown() }

    // MARK: The name apps see

    /// Renames the virtual mic to match `micName`. Needs a driver that allows it; older ones don't.
    private func applyMicName() {
        guard let mic = micDevice else { return }
        let current = HAL.string(mic, kAudioObjectPropertyName) ?? Brand.micName
        micDisplayName = current
        if renameTried == nil { canRenameMic = HAL.micBox() != nil }
        let wanted = micName.trimmingCharacters(in: .whitespaces)
        let target = wanted.isEmpty ? Brand.micName : wanted
        guard target != current, target != renameTried else { return }
        renameTried = target
        guard HAL.rename(to: wanted) else { canRenameMic = false; return }
        // The driver reports the new name a moment later. An older driver takes the call and changes nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let mic = self.micDevice else { return }
            let now = HAL.string(mic, kAudioObjectPropertyName) ?? Brand.micName
            self.micDisplayName = now
            self.canRenameMic = now == target
        }
    }

    // MARK: Status in words

    /// Names of the apps reading the virtual mic right now.
    @Published var listeners: [String] = []
    /// The icon of the first app using the mic, when it is an app with one.
    @Published var listenerIcon: NSImage?
    private var listenerPID: pid_t = 0

    var markState: AppMark.State { muted ? .muted : recording ? .recording : running ? .live : .idle }

    var statusColor: Color {
        if recording { return .red }
        if muted { return .orange }
        return running ? .green : .secondary
    }

    var statusTitle: String {
        if !driverInstalled { return "Driver missing" }
        if recording { return "Recording" }
        if muted { return "Muted" }
        if !running { return "Mic off" }
        let who = Self.sentenceList(listeners)
        if !who.isEmpty { return "\(who) \(listeners.count == 1 ? "is" : "are") using the mic" }
        return listenBack ? "Listening to yourself" : monitoring ? "Mic open for the live view" : "Mic open"
    }

    var statusDetail: String {
        if !driverInstalled { return "Run the installer to put the microphone back" }
        let who = Self.sentenceList(listeners)
        if muted { return who.isEmpty ? "The mic stays closed" : "\(who) \(listeners.count == 1 ? "hears" : "hear") silence" }
        if recording { return "Saving to \(recordingsURL.lastPathComponent)" }
        if !running { return "No app is using it" }
        return ""
    }

    private static func sentenceList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) others"
        }
    }

    private func refreshListeners() {
        let now = clientsActive, let_mic = micDevice
        guard now, let mic = let_mic else { if !listeners.isEmpty { listeners = []; listenerIcon = nil; listenerPID = 0 }; return }
        let clients = HAL.inputClients(of: mic), names = clients.map(\.name)
        if names != listeners { listeners = names }
        let pid = clients.first?.pid ?? 0
        if pid != listenerPID { listenerPID = pid; listenerIcon = pid == 0 ? nil : NSRunningApplication(processIdentifier: pid)?.icon }
    }

    // MARK: System microphone

    private func refreshSystemMicrophone() {
        isSystemMicrophone = HAL.defaultInputUID() == Brand.micUID
    }

    /// Points the Mac's input setting at the virtual mic, or puts it back where it was.
    func setSystemMicrophone(_ on: Bool) {
        let d = UserDefaults.standard
        if on {
            guard let mic = micDevice else { return }
            if let current = HAL.defaultInputUID(), current != Brand.micUID { d.set(current, forKey: "previousSystemInput") }
            if !HAL.setDefaultInput(mic) { error = "Couldn't change the Mac's input setting." }
        } else {
            let back = d.string(forKey: "previousSystemInput").flatMap(HAL.device(uid:)) ?? HAL.device(uid: inputUID)
            if let back, !HAL.setDefaultInput(back) { error = "Couldn't change the Mac's input setting." }
        }
        refreshSystemMicrophone()
    }

    // MARK: On-demand start/stop

    private func clientsChanged() {
        guard let mic = micDevice else { return }
        clientsActive = HAL.uint32(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
        refreshListeners()
        evaluate()
    }

    private func evaluate() {
        let want = (clientsActive && !muted) || recording || monitoring || listenBack
        if want && !running { start() } else if !want && running { stop() }
    }

    private func start() {
        guard let p = ioProc, aggregate != kAudioObjectUnknown else { return }
        firstCallbackAt = 0
        wakeRequestedAt = mach_absolute_time()
        let err = AudioDeviceStart(aggregate, p)
        if err == noErr { running = true } else { error = "Couldn't open the microphone (error \(err))." }
    }

    private func stop() {
        guard running, let p = ioProc else { return }
        AudioDeviceStop(aggregate, p)
        running = false
        level = 0
        reductionDB = 0
    }

    // MARK: Audio thread

    private func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        if firstCallbackAt == 0 { firstCallbackAt = mach_absolute_time() }
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let src = ins.first, let srcData = src.mData, src.mNumberChannels > 0 else { return }
        let ch = Int(src.mNumberChannels)
        let frames = min(Int(src.mDataByteSize) / (4 * ch), Self.maxFrames)
        let s = srcData.assumingMemoryBound(to: Float.self)
        let stereo = stereoFlag && ch >= 2
        for n in 0..<frames { left[n] = s[n * ch] }
        if stereo { for n in 0..<frames { right[n] = s[n * ch + 1] } }

        if recordFlag {
            memcpy(rawLeft, left, frames * 4)
            if stereo { memcpy(rawRight, right, frames * 4) }
        }
        let mask = Self.ringSize - 1, at = ringIndex
        for n in 0..<frames { rawRing[(at + n) & mask] = left[n] }
        if captureFlag, let capture {
            let k = min(captureGoal - captureCount, frames)
            if k > 0 { memcpy(capture + captureCount, left, k * 4); captureCount += k }
        }

        dsp.process(left, right, frames: frames, stereo: stereo)

        for n in 0..<frames { postRing[(at + n) & mask] = left[n] }
        ringIndex = (at + frames) & mask

        var p = peak
        for n in 0..<frames { let v = abs(left[n]); if v > p { p = v } }
        if stereo { for n in 0..<frames { let v = abs(right[n]); if v > p { p = v } } }
        peak = p

        if recordFlag, let file = recordFile {
            write(file, left, right, frames: frames, stereo: stereo)
            if let raw = recordRawFile { write(raw, rawLeft, rawRight, frames: frames, stereo: stereo) }
        }

        guard !mutedFlag, let dst = outs.last, let dstData = dst.mData, dst.mNumberChannels > 0 else { return }
        let och = Int(dst.mNumberChannels)
        let oframes = min(frames, Int(dst.mDataByteSize) / (4 * och))
        let o = dstData.assumingMemoryBound(to: Float.self)
        for n in 0..<oframes {
            o[n * och] = left[n]
            if och > 1 { o[n * och + 1] = stereo ? right[n] : left[n] }
        }
    }

    private func write(_ file: ExtAudioFileRef, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int, stereo: Bool) {
        if stereo {
            for n in 0..<frames { interleaved[n * 2] = l[n]; interleaved[n * 2 + 1] = r[n] }
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: interleaved))
            ExtAudioFileWriteAsync(file, UInt32(frames), &abl)
        } else {
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l))
            ExtAudioFileWriteAsync(file, UInt32(frames), &abl)
        }
    }

    private func tick() {
        ticks += 1
        if ticks % 10 == 0 {
            if HAL.device(uid: Brand.micUID) != micDevice { listenerDevice = nil; rebuild() }
            // Another app can change the mic's sample rate. The EQ is computed for one rate, so follow it.
            else if builtRate > 0, let source = HAL.device(uid: inputUID), HAL.sampleRate(source) != builtRate { rebuild() }
            pollConfig(); refreshListeners(); writeStatus()
            if ticks % 20 == 0 || gainLockDB != nil { refreshMicGain() }
        }
        if auditioning != nil {
            if player.finished { stopAudition() } else {
                auditionProgress = player.progress
                analyze(raw: player.rawRing, post: player.postRing, end: player.ringIndex, rate: player.sampleRate)
            }
        }
        guard running else { return }
        level = peak; peak = 0
        reductionDB = dsp.reductionMeter; dsp.reductionMeter = 0
        limiterDB = dsp.limiterMeter; dsp.limiterMeter = 0
        if monitoring, auditioning == nil { analyze(raw: rawRing, post: postRing, end: ringIndex, rate: sampleRate) }
        if captureFlag { measureProgress = Double(captureCount) / Double(max(captureGoal, 1)); if captureCount >= captureGoal { finishMeasure() } }
        if firstCallbackAt != 0, wakeRequestedAt != 0 {
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            lastWakeMs = Double(firstCallbackAt - wakeRequestedAt) * Double(tb.numer) / Double(tb.denom) / 1e6
            wakeRequestedAt = 0
        }
    }

    // MARK: Live analysis

    private func analyze(raw: UnsafeMutablePointer<Float>, post postRing: UnsafeMutablePointer<Float>, end: Int, rate: Double) {
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
        spectrumRaw = levels(rawRing, spectrumRaw)
        let post = levels(postRing, [])
        spectrumPost = spectrumPost.count == post.count ? zip(post, spectrumPost).map { $0 > $1 ? $1 + ($0 - $1) * 0.6 : $1 + ($0 - $1) * 0.12 } : post

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
            spectrogram = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Quiet to loud: near-black, deep blue, magenta, orange, pale yellow.
    private static func heat(_ t: Float) -> (UInt8, UInt8, UInt8) {
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

    private func finishMeasure() {
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

    private func refit() {
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

    // MARK: config.json and status.json

    private var activeProfile: MicProfile {
        var p = MicProfile()
        p.name = inputs.first(where: { $0.uid == inputUID })?.name ?? mics[inputUID]?.name ?? ""
        p.equalizer = !bypass; p.outputGainDB = outputGainDB; p.bands = bands; p.dynamics = dynamics; p.gainLockDB = gainLockDB
        return p
    }

    private var settings: Settings {
        var s = Settings()
        s.muted = muted; s.inputUID = inputUID; s.icon = icon; s.appIcon = appIcon; s.showInDock = showInDock; s.autoUpdate = autoUpdate; s.updateFeed = updateFeed; s.returnToUID = returnTo ?? ""; s.recordingsFolder = recordingsFolder; s.micName = micName; s.muteShortcut = muteShortcut; s.recordShortcut = recordShortcut
        s.mics = mics
        s.presets = presets
        if !inputUID.isEmpty { s.mics[inputUID] = activeProfile }
        return s
    }

    private func load(_ p: MicProfile) {
        let was = applying
        applying = true
        if p.equalizer == bypass { bypass = !p.equalizer }
        if p.outputGainDB != outputGainDB { outputGainDB = p.outputGainDB }
        if p.gainLockDB != gainLockDB { gainLockDB = p.gainLockDB }
        if p.bands != bands { bands = p.bands }
        if p.dynamics != dynamics { dynamics = p.dynamics }
        applying = was
    }

    /// The microphone changed: keep the old one's sound, bring in the new one's. A microphone seen
    /// for the first time starts flat.
    private func switchProfile(from old: String) {
        guard !applying else { return }
        if !old.isEmpty {
            var p = activeProfile
            p.name = inputs.first(where: { $0.uid == old })?.name ?? mics[old]?.name ?? ""
            mics[old] = p
        }
        load(mics[inputUID] ?? MicProfile())
    }

    // MARK: Presets

    /// The preset the current sound matches exactly, if any.
    var currentPreset: SoundPreset? { let now = activeProfile; return presets.first { $0.matches(now) } }

    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        SoundPreset.save(SoundPreset(name: name, from: activeProfile), in: &presets)
    }

    func use(_ preset: SoundPreset) {
        var p = activeProfile
        preset.apply(to: &p)
        p.bands = p.bands.map { var b = $0; b.id = UUID(); return b }
        load(p)
        changed()
    }

    func deletePreset(_ preset: SoundPreset) { presets.removeAll { $0.id == preset.id } }

    // MARK: History

    /// Remembers the curve from before a run of edits. A drag is hundreds of small changes, so the
    /// snapshot is taken once the curve has been still for a moment.
    private func noteHistory(_ old: [Band]) {
        guard historyUID == inputUID else { historyUID = inputUID; historyBefore = nil; return } // another mic's curve came in
        guard old != bands else { return }
        if historyBefore == nil { historyBefore = old }
        historyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let before = self.historyBefore else { return }
            self.historyBefore = nil
            guard before != self.bands, self.history.first?.bands != before else { return }
            let name = self.inputs.first(where: { $0.uid == self.inputUID })?.name ?? ""
            self.history.insert(EQSnapshot(date: Date(), mic: name, bands: before), at: 0)
            if self.history.count > 40 { self.history.removeLast(self.history.count - 40) }
            EQSnapshot.save(self.history)
        }
        historyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Brings an earlier curve back. The curve it replaces goes into the history in turn.
    func restore(_ snapshot: EQSnapshot) { bands = snapshot.bands.map { var b = $0; b.id = UUID(); return b } }

    func clearHistory() { history = []; EQSnapshot.save(history) }

    // MARK: Listen back

    private func applyListenBack() {
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
    private func outputChanged() {
        guard listenBack else { return }
        listenBack = false
        if !ListenBack.outputIsBuiltInSpeakers { listenBack = true }
    }

    // MARK: Hardware gain

    /// Reads the gain, and when it is locked, puts it back if something else has moved it.
    private func refreshMicGain() {
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

    /// A change made in the app. Saved shortly after it settles, unless config.json is broken:
    /// then nothing is written, so a hand edit in progress is never overwritten.
    private func changed() {
        guard !applying, configProblem == nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settings.save()
            self.configStamp = Settings.modified()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Picks up edits made to config.json by hand, by a script or by an agent.
    private func pollConfig() {
        let stamp = Settings.modified()
        guard stamp != configStamp else { return }
        configStamp = stamp
        switch Settings.load() {
        case .missing: break
        case .invalid(let why): configProblem = why
        case .ok(let s):
            configProblem = nil
            guard s != settings else { return }
            applying = true
            mics = s.mics
            if s.muted != muted { muted = s.muted }
            if s.icon != icon { icon = s.icon }
            if s.appIcon != appIcon { appIcon = s.appIcon }
            if s.showInDock != showInDock { showInDock = s.showInDock }
            if s.autoUpdate != autoUpdate { autoUpdate = s.autoUpdate }
            if s.updateFeed != updateFeed { updateFeed = s.updateFeed }
            if s.presets != presets { presets = s.presets }
            if s.returnToUID != (returnTo ?? "") { returnTo = s.returnToUID.isEmpty ? nil : s.returnToUID }
            if s.recordingsFolder != recordingsFolder { recordingsFolder = s.recordingsFolder }
            if s.muteShortcut != muteShortcut { muteShortcut = s.muteShortcut }
            if s.recordShortcut != recordShortcut { recordShortcut = s.recordShortcut }
            if s.micName != micName { micName = s.micName }
            if s.inputUID != inputUID, inputs.contains(where: { $0.uid == s.inputUID }) { inputUID = s.inputUID }
            applying = false
            load(mics[inputUID] ?? MicProfile())
        }
    }

    private func writeStatus() {
        let st = Status(driverInstalled: driverInstalled, micOpen: running, appListening: clientsActive, systemMicrophone: isSystemMicrophone, muted: muted, recording: recording,
                        input: inputs.first(where: { $0.uid == inputUID })?.name ?? "", sampleRate: sampleRate,
                        lastWakeMs: lastWakeMs.map { ($0 * 10).rounded() / 10 }, lastRecording: lastRecording?.path, problem: configProblem ?? error, usedBy: listeners, micName: micDisplayName, playing: auditioning?.lastPathComponent)
        guard st != lastStatus else { return }
        lastStatus = st
        st.save()
    }

    func handle(command: String) {
        switch command {
        case "record-start": if !recording { toggleRecording() }
        case "record-stop": if recording { toggleRecording() }
        case "record-toggle": toggleRecording()
        case "system-on": setSystemMicrophone(true)
        case "system-off": setSystemMicrophone(false)
        case "listen-on": listenBack = true
        case "listen-off": listenBack = false
        case "gain-lock": setGainLock(true)
        case "gain-unlock": setGainLock(false)
        case _ where command.hasPrefix("gain "): if let v = Double(command.dropFirst(5)) { refreshMicGain(); setMicGain(v) }
        case _ where command.hasPrefix("history-restore "): if let n = Int(command.dropFirst(16)), history.indices.contains(n - 1) { restore(history[n - 1]) }
        case "history-clear": clearHistory()
        case "play-stop": stopAudition()
        case _ where command.hasPrefix("play "):
            let want = String(command.dropFirst(5))
            if let r = Recording.list(in: recordingsURL).first(where: { $0.url.lastPathComponent == want || $0.url.deletingPathExtension().lastPathComponent == want }) {
                if r.raw != nil { startAudition(r) } else { error = "That recording has no raw take, so it can't be replayed through the EQ." }
            } else { error = "No recording is named \(want)." }
        case _ where command.hasPrefix("autoeq-measure"):
            // autoeq-measure <seconds> <target> <strength> <apply|keep>
            let p = command.split(separator: " ").map(String.init)
            let out = Settings.directory.appendingPathComponent("autoeq.json")
            if p.count > 2, let t = AutoEQ.Target(rawValue: p[2]) { autoTarget = t }
            if p.count > 3, let v = Double(p[3]) { autoStrength = v }
            let apply = p.count > 4 && p[4] == "apply"
            startMeasure(seconds: p.count > 1 ? Double(p[1]) ?? 20 : 20) { [weak self] result in
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
                var data = try? e.encode(["error": self?.autoProblem ?? "The measurement didn't finish."])
                if var r = result { r.centres = []; r.measured = []; r.wanted = []; data = try? e.encode(r) }
                try? data?.write(to: out, options: .atomic)
                if apply, result != nil { self?.useAutoEQ() }
            }
        default: break
        }
        writeStatus()
    }

    // MARK: Recording

    func toggleRecording() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        guard driverInstalled, ioProc != nil else { return }
        let dir = recordingsURL
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { self.error = "Couldn't use the recordings folder at \(dir.path). Choose another one."; return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("\(f.string(from: Date())).wav")
        guard let file = makeFile(url) else { error = "Couldn't create the recording file."; return }
        recordFile = file
        // The raw take, hidden beside it, so the recording can be replayed through a different EQ later.
        recordRawFile = makeFile(Recording.rawURL(for: url))
        recordFlag = true
        recording = true
        lastRecording = url
        evaluate()
    }

    private func makeFile(_ url: URL) -> ExtAudioFileRef? {
        let channels: UInt32 = stereoFlag ? 2 : 1
        var fileFmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 3 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 3 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
        var clientFmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var file: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFmt, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr, let file else { return nil }
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt)
        ExtAudioFileWriteAsync(file, 0, nil) // allocate the async buffers off the audio thread
        return file
    }

    private func stopRecording() {
        guard recording else { return }
        recordFlag = false
        recording = false
        evaluate()
        let file = recordFile, raw = recordRawFile
        recordFile = nil; recordRawFile = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            if let file { ExtAudioFileDispose(file) }
            if let raw { ExtAudioFileDispose(raw) }
            DispatchQueue.main.async { [weak self] in self?.refreshRecordings() }
        }
    }

    /// Moves recordings to the Trash, where they can be put back.
    func trash(_ items: [Recording]) {
        for r in items {
            if auditioning == r.url { stopAudition() }
            try? FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
            if let raw = r.raw { try? FileManager.default.trashItem(at: raw, resultingItemURL: nil) }
        }
        refreshRecordings()
    }

    /// Plays a recording's raw take through the current EQ, gate and compressor.
    func startAudition(_ r: Recording) {
        guard let raw = r.raw else { return }
        stopAudition()
        player.loop = auditionLoop
        guard player.start(raw) else { error = "Couldn't play that recording."; return }
        auditioning = r.url
        pushDSP()
    }

    func stopAudition() {
        guard auditioning != nil else { return }
        player.stop()
        auditioning = nil
        auditionProgress = 0
        if !monitoring { spectrumPost = []; spectrumRaw = []; spectrogram = nil; historyColumn = 0 }
    }

    var recordingsURL: URL { var s = Settings(); s.recordingsFolder = recordingsFolder; return s.recordingsURL }

    func refreshRecordings() {
        let folder = recordingsURL
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Recording.list(in: folder)
            DispatchQueue.main.async { [weak self] in if self?.recordingsURL == folder { self?.recordings = list } }
        }
    }

    // MARK: Settings

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "Couldn't change the start-at-login setting: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func pushDSP() {
        dsp.set(bands: bands, dynamics: dynamics, sampleRate: sampleRate, outputGainDB: outputGainDB, bypass: bypass)
        if auditioning != nil { player.chain.set(bands: bands, dynamics: dynamics, sampleRate: player.sampleRate, outputGainDB: outputGainDB, bypass: bypass) }
    }
    func responseDB(at f: Double) -> Double {
        guard !bypass else { return 0 }
        return bands.filter(\.on).reduce(outputGainDB) { $0 + Coeffs.make($1, sampleRate: sampleRate).magnitudeDB(at: f, sampleRate: sampleRate) }
    }
}
