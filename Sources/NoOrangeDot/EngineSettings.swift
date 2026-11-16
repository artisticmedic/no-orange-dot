import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: config.json and status.json

    var activeProfile: MicProfile {
        var p = MicProfile()
        p.name = micName(for: inputUID) ?? ""
        p.equalizer = !bypass; p.outputGainDB = outputGainDB; p.bands = bands; p.dynamics = dynamics; p.gainLockDB = gainLockDB
        return p
    }

    var settings: Settings {
        var s = Settings()
        s.muted = muted; s.inputUID = inputUID; s.icon = icon; s.appIcon = appIcon; s.showInDock = showInDock; s.autoUpdate = autoUpdate; s.updateFeed = updateFeed; s.micOrder = micOrder; s.recordingsFolder = recordingsFolder; s.micName = micName; s.muteShortcut = muteShortcut; s.recordShortcut = recordShortcut; s.shortcuts = shortcuts
        s.mics = mics
        s.presets = presets
        if !inputUID.isEmpty { s.mics[inputUID] = activeProfile }
        return s
    }

    func load(_ p: MicProfile) {
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
    func switchProfile(from old: String) {
        guard !applying else { return }
        if !old.isEmpty {
            var p = activeProfile
            p.name = micName(for: old) ?? ""
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
    func noteHistory(_ old: [Band]) {
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

    /// A change made in the app. Saved shortly after it settles, unless config.json is broken:
    /// then nothing is written, so a hand edit in progress is never overwritten.
    func changed() {
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
    func pollConfig() {
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
            if s.micOrder != micOrder { micOrder = s.micOrder }
            if s.recordingsFolder != recordingsFolder { recordingsFolder = s.recordingsFolder }
            if s.muteShortcut != muteShortcut { muteShortcut = s.muteShortcut }
            if s.recordShortcut != recordShortcut { recordShortcut = s.recordShortcut }
            if s.shortcuts != shortcuts { shortcuts = s.shortcuts }
            if s.micName != micName { micName = s.micName }
            if s.inputUID != inputUID, inputs.contains(where: { $0.uid == s.inputUID }) { inputUID = s.inputUID }
            applying = false
            load(mics[inputUID] ?? MicProfile())
            if preferredInput != inputUID { rebuild() }
            if micOrder != s.micOrder { changed() }
        }
    }

    func writeStatus() {
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
}
