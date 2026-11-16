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
    let meters = Meters()
    let scope = Scope()
    @Published var muteShortcut = "" { didSet { if muteShortcut != oldValue { changed() } } }
    @Published var recordShortcut = "" { didSet { if recordShortcut != oldValue { changed() } } }
    /// Shortcuts the user gave to menu commands, by command ID. They work while this app is in front.
    @Published var shortcuts: [String: String] = [:] { didSet { if shortcuts != oldValue { changed() } } }
    @Published var selectedBand: UUID?
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
            switchProfile(from: oldValue); rebuild(); changed()
        }
    }
    /// These microphones take priority over other available inputs, in this order.
    @Published var micOrder: [String] = [] {
        didSet { if micOrder != oldValue { manualInputUID = nil; changed() } }
    }
    /// Names of microphones seen since launch, so one that was just unplugged keeps its name.
    var seenNames: [String: String] = [:]
    var manualInputUID: String?
    var builtRate = 0.0
    /// Every microphone's saved sound. The one in use is mirrored in `bands`, `dynamics`, `bypass` and `outputGainDB`.
    var mics: [String: MicProfile] = [:]
    @Published var bands: [Band] {
        didSet {
            // The built-in curves reuse their band IDs, so a selection left behind would come back with them.
            if let id = selectedBand, !bands.contains(where: { $0.id == id }) { selectedBand = nil }
            noteHistory(oldValue); pushDSP(); changed()
        }
    }
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
    let listener = ListenBack()
    @Published var gainLockDB: Double? { didSet { if gainLockDB != oldValue { changed(); refreshMicGain() } } }
    var historyBefore: [Band]?
    var historyWork: DispatchWorkItem?
    var historyUID = ""
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
    @Published var monitoring = false { didSet { evaluate(); if !monitoring { scope.clear(); historyColumn = 0 } } }
    // Replaying a raw take through the EQ, to hear a change on the same words.
    @Published var auditioning: URL?
    @Published var auditionLoop = true { didSet { player.loop = auditionLoop } }
    let player = AuditionPlayer()

    @Published var measureProgress: Double?     // 0...1 while automatic EQ is listening, otherwise nil
    @Published var autoResult: AutoEQ.Result?
    @Published var autoProblem: String?
    @Published var autoTarget: AutoEQ.Target = .warm { didSet { refit() } }
    @Published var autoStrength = 1.0 { didSet { refit() } }

    /// Twelfth-octave centres from 40 Hz to about 15 kHz, for drawing.
    static let displayCentres: [Double] = (0..<104).map { 40 * pow(2, Double($0) / 12) }
    static let displayFloor: Float = -100, displayCeiling: Float = -15
    static let ringSize = 8192
    let rawRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    let postRing = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    var ringIndex = 0
    let analyzer = Spectrum(size: 4096)
    static let historyWidth = 180
    var heat = [UInt8](repeating: 0, count: historyWidth * 104 * 4)
    var historyColumn = 0
    var capture: UnsafeMutablePointer<Float>?
    var captureCapacity = 0, captureCount = 0, captureGoal = 0
    var captureFlag = false
    var measured: (samples: [Float], levels: [Double], seconds: Double, sampleRate: Double)?
    var measureDone: ((AutoEQ.Result?) -> Void)?
    var monitoringBeforeMeasure = false

    var applying = false
    var saveWork: DispatchWorkItem?
    var configStamp: Date?
    var lastStatus = Status()
    var ticks = 0

    private(set) var sampleRate = 48000.0
    let dsp = DSPChain()
    var micDevice: AudioDeviceID?
    var aggregate: AudioDeviceID = kAudioObjectUnknown
    var ioProc: AudioDeviceIOProcID?
    var listenerDevice: AudioDeviceID?
    var renameTried: String?
    var meterTimer: Timer?
    var deviceSignature = ""

    // Touched from the audio thread. Plain stores; no locks, no allocation.
    static let maxFrames = 16384
    let left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
    var mutedFlag = false
    var stereoFlag = false
    var recordFlag = false
    var recordFile: ExtAudioFileRef?
    var recordRawFile: ExtAudioFileRef?
    let rawLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let rawRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    var peak: Float = 0
    var wakeRequestedAt: UInt64 = 0
    var firstCallbackAt: UInt64 = 0

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
        micOrder = s.micOrder
        historyUID = s.inputUID
        recordingsFolder = s.recordingsFolder
        muteShortcut = s.muteShortcut
        recordShortcut = s.recordShortcut
        shortcuts = s.shortcuts
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

    /// Names of the apps reading the virtual mic right now.
    @Published var listeners: [String] = []
    /// The icon of the first app using the mic, when it is an app with one.
    @Published var listenerIcon: NSImage?
    var listenerPID: pid_t = 0

    var aggregateUID = ""
    var aggregateCount = 0

    // MARK: Setup

    /// Creating our own private aggregate also fires the device-list listener, so only rebuild when
    /// the real inputs or the driver actually changed. Otherwise the engine tears itself down in a loop.
    func currentSignature() -> String {
        let driver = HAL.device(uid: Brand.micUID) != nil && HAL.device(uid: Brand.feedUID) != nil
        return HAL.inputDevices().map(\.uid).sorted().joined(separator: "|") + (driver ? "#driver" : "")
    }

    func devicesChanged() {
        let signature = currentSignature()
        guard signature != deviceSignature else { return }
        let pick = refreshInputs()
        let driver = HAL.device(uid: Brand.micUID) != nil && HAL.device(uid: Brand.feedUID) != nil
        if pick != inputUID || driver != driverInstalled { rebuild() }
        else { deviceSignature = signature }
    }

    private func refreshInputs() -> String {
        let previouslyAvailable = inputs.map(\.uid)
        inputs = HAL.inputDevices()
        var namesChanged = false
        for input in inputs {
            if micName(for: input.uid) != input.name { namesChanged = true }
            seenNames[input.uid] = input.name
        }
        if namesChanged { changed() }
        let pick = MicrophonePriority.select(order: micOrder, available: inputs.map(\.uid),
                                             previouslyAvailable: previouslyAvailable, manual: manualInputUID, current: inputUID)
        if pick != manualInputUID { manualInputUID = nil }
        return pick ?? ""
    }

    func coreAudioRestarted() {
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
        let pick = refreshInputs()
        if pick != inputUID {
            inputUID = pick; return // didSet re-enters rebuild
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

        // After Core Audio restarts, the aggregate made before can come back under its old name while this
        // app no longer holds it. A second one with the same name is refused, so remove the old one and
        // give each new one its own name.
        if let stale = HAL.device(uid: aggregateUID) { AudioHardwareDestroyAggregateDevice(stale) }
        aggregateCount += 1
        aggregateUID = "\(Brand.bundleID).engine.\(getpid()).\(aggregateCount)"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Brand.short) Engine",
            kAudioAggregateDeviceUIDKey: aggregateUID,
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

    func teardown() {
        if let p = ioProc, aggregate != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggregate, p) }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = kAudioObjectUnknown
    }

    func shutdown() { stopRecording(); stop(); teardown() }

    // MARK: The name apps see

    /// Renames the virtual mic to match `micName`. Needs a driver that allows it; older ones don't.
    func applyMicName() {
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

    // MARK: System microphone

    func refreshSystemMicrophone() {
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

    func clientsChanged() {
        guard let mic = micDevice else { return }
        clientsActive = HAL.uint32(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
        refreshListeners()
        evaluate()
    }

    func evaluate() {
        let want = (clientsActive && !muted) || recording || monitoring || listenBack
        if want && !running { start() } else if !want && running { stop() }
    }

    func start() {
        guard let p = ioProc, aggregate != kAudioObjectUnknown else { return }
        firstCallbackAt = 0
        wakeRequestedAt = mach_absolute_time()
        let err = AudioDeviceStart(aggregate, p)
        if err == noErr { running = true } else { error = "Couldn't open the microphone (error \(err))." }
    }

    func stop() {
        guard running, let p = ioProc else { return }
        AudioDeviceStop(aggregate, p)
        running = false
        meters.level = 0
        meters.reductionDB = 0
    }

    // MARK: Audio thread

    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
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

    func write(_ file: ExtAudioFileRef, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int, stereo: Bool) {
        if stereo {
            for n in 0..<frames { interleaved[n * 2] = l[n]; interleaved[n * 2 + 1] = r[n] }
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: interleaved))
            ExtAudioFileWriteAsync(file, UInt32(frames), &abl)
        } else {
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l))
            ExtAudioFileWriteAsync(file, UInt32(frames), &abl)
        }
    }

    func tick() {
        ticks += 1
        if ticks % 10 == 0 {
            if HAL.device(uid: Brand.micUID) != micDevice { listenerDevice = nil; rebuild() }
            // Another app can change the mic's sample rate. The EQ is computed for one rate, so follow it.
            else if builtRate > 0, let source = HAL.device(uid: inputUID), HAL.sampleRate(source) != builtRate { rebuild() }
            // Setup can fail while Core Audio is still restarting. Keep trying until it holds.
            else if driverInstalled, !inputUID.isEmpty, ioProc == nil, ticks % 40 == 0 { rebuild() }
            pollConfig(); writeStatus()
            if ticks % 20 == 0 { refreshListeners() }
            if ticks % 20 == 0 || gainLockDB != nil { refreshMicGain() }
        }
        if auditioning != nil {
            if player.finished { stopAudition() } else {
                meters.auditionProgress = player.progress
                analyze(raw: player.rawRing, post: player.postRing, end: player.ringIndex, rate: player.sampleRate)
            }
        }
        guard running else { return }
        meters.level = peak; peak = 0
        meters.reductionDB = dsp.reductionMeter; dsp.reductionMeter = 0
        meters.limiterDB = dsp.limiterMeter; dsp.limiterMeter = 0
        if monitoring, auditioning == nil { analyze(raw: rawRing, post: postRing, end: ringIndex, rate: sampleRate) }
        if captureFlag { measureProgress = Double(captureCount) / Double(max(captureGoal, 1)); if captureCount >= captureGoal { finishMeasure() } }
        if firstCallbackAt != 0, wakeRequestedAt != 0 {
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            lastWakeMs = Double(firstCallbackAt - wakeRequestedAt) * Double(tb.numer) / Double(tb.denom) / 1e6
            wakeRequestedAt = 0
        }
    }

    // MARK: Settings

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "Couldn't change the start-at-login setting: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func pushDSP() {
        dsp.set(bands: bands, dynamics: dynamics, sampleRate: sampleRate, outputGainDB: outputGainDB, bypass: bypass)
        if auditioning != nil { player.chain.set(bands: bands, dynamics: dynamics, sampleRate: player.sampleRate, outputGainDB: outputGainDB, bypass: bypass) }
    }
    func responseDB(at f: Double) -> Double {
        guard !bypass else { return 0 }
        return bands.filter(\.on).reduce(outputGainDB) { $0 + Coeffs.make($1, sampleRate: sampleRate).magnitudeDB(at: f, sampleRate: sampleRate) }
    }
}
