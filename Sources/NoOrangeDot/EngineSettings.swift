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
        s.muted = muted; s.systemMicrophone = keepSystemMicrophone; s.inputUID = inputUID; s.icon = icon; s.appIcon = appIcon; s.showInDock = showInDock; s.autoUpdate = autoUpdate; s.updateFeed = updateFeed; s.micOrder = micOrder; s.recordingsFolder = recordingsFolder; s.micName = micName; s.muteShortcut = muteShortcut; s.recordShortcut = recordShortcut; s.shortcuts = shortcuts
        s.mics = mics
        for (uid, name) in seenNames {
            var profile = s.mics[uid] ?? MicProfile()
            profile.name = name
            s.mics[uid] = profile
        }
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
        flushHistory()
        if !old.isEmpty {
            var p = activeProfile
            p.name = micName(for: old) ?? ""
            mics[old] = p
        }
        eqHistory.selectMic(inputUID, name: micName(for: inputUID) ?? "")
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
        lastPreset = preset.id
        flushHistory()
        let old = bands
        var p = activeProfile
        preset.apply(to: &p)
        p.bands = p.bands.map { var b = $0; b.id = UUID(); return b }
        load(p)
        noteHistory(old)
        flushHistory()
        changed()
    }

    func deletePreset(_ preset: SoundPreset) { presets.removeAll { $0.id == preset.id } }

    // MARK: History

    var history: [EQSnapshot] { eqHistory.snapshots }
    var canUndoEQ: Bool { eqHistory.canUndo }
    var canRedoEQ: Bool { eqHistory.canRedo }

    /// Group a drag into one edit, while allowing Undo before the debounce finishes.
    func noteHistory(_ old: [Band]) {
        guard !applying, old != bands else { return }
        eqHistory.selectMic(inputUID, name: micName(for: inputUID) ?? "")
        eqHistory.record(before: old, after: bands)
        historyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushHistory() }
        historyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func flushHistory() {
        historyWork?.cancel(); historyWork = nil
        if eqHistory.flush() { saveHistory() }
    }

    private func saveHistory() {
        do {
            if let archive = historyArchive {
                historyArchive = try EQSnapshot.save(history, expecting: archive.revision)
            } else {
                let archive = try EQSnapshot.read()
                historyArchive = archive
                eqHistory.replaceSnapshots(archive.snapshots)
            }
        } catch {
            switch error {
            case EQSnapshot.Failure.write: break
            default:
                if let archive = try? EQSnapshot.read() {
                    historyArchive = archive
                    eqHistory.replaceSnapshots(archive.snapshots)
                } else { historyArchive = nil }
            }
            self.error = error.localizedDescription
        }
    }

    func undoEQ() {
        historyWork?.cancel(); historyWork = nil
        guard let previous = eqHistory.undo(current: bands) else { return }
        applyHistoryCurve(previous)
        saveHistory()
    }

    func redoEQ() {
        historyWork?.cancel(); historyWork = nil
        guard let next = eqHistory.redo(current: bands) else { return }
        applyHistoryCurve(next)
        saveHistory()
    }

    private func applyHistoryCurve(_ curve: [Band]) {
        let was = applying
        applying = true
        bands = curve.map { var band = $0; band.id = UUID(); return band }
        applying = was
        changed()
    }

    /// Browsing an earlier curve creates a new undoable edit; it does not consume the archive.
    func restore(_ snapshot: EQSnapshot) {
        flushHistory()
        bands = snapshot.bands.map { var band = $0; band.id = UUID(); return band }
        flushHistory()
    }

    func clearHistory() {
        historyWork?.cancel(); historyWork = nil
        eqHistory.clear()
        saveHistory()
    }

    func flushPendingChanges() {
        flushHistory()
        if let archive = historyArchive, archive.snapshots != history { saveHistory() }
        saveWork?.cancel(); saveWork = nil
        guard let snapshot = configSnapshot, settings != snapshot.settings else { return }
        do {
            configSnapshot = try Settings.store.save(settings, expecting: snapshot.revision)
            configProblem = nil
        } catch { configProblem = error.localizedDescription }
    }

    /// A pending app edit may replace only the disk version it was based on.
    func changed() {
        guard !applying, let snapshot = configSnapshot else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWork = nil
            do {
                self.configSnapshot = try Settings.store.save(self.settings, expecting: snapshot.revision)
                self.configProblem = nil
            } catch {
                self.pollConfig()
                self.configProblem = error.localizedDescription
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// External changes win over pending app edits, including invalid or unreadable files.
    func pollConfig() {
        let snapshot: SettingsStore.Snapshot
        do { snapshot = try Settings.store.read() }
        catch {
            saveWork?.cancel(); saveWork = nil
            configSnapshot = nil
            configProblem = error.localizedDescription
            return
        }
        if let current = configSnapshot, snapshot.revision == current.revision { return }
        saveWork?.cancel(); saveWork = nil
        configSnapshot = snapshot
        configProblem = nil
        let s = snapshot.settings
        guard s != settings else { return }
        flushHistory()
        let oldInputUID = inputUID, oldBands = bands
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
        if s.inputUID != inputUID, inputs.contains(where: { $0.uid == s.inputUID }) { chooseInput(s.inputUID) }
        applying = false
        if let keep = s.systemMicrophone, keep != keepSystemMicrophone { setSystemMicrophone(keep) }
        eqHistory.selectMic(inputUID, name: micName(for: inputUID) ?? "")
        load(mics[inputUID] ?? MicProfile())
        if inputUID == oldInputUID, bands != oldBands {
            eqHistory.replace(before: oldBands, after: bands)
            saveHistory()
        }
        if (selectedInput ?? "") != inputUID { rebuild() }
        if micOrder != s.micOrder { changed() }
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
        case _ where command.hasPrefix("history-restore "): if let n = Int(command.dropFirst(16)), n >= 1, n <= history.count { restore(history[n - 1]) }
        case "history-clear": clearHistory()
        case "play-stop": MainActor.assumeIsolated { stopPlaying() }
        case _ where command.hasPrefix("play "):
            let want = String(command.dropFirst(5))
            if let r = Recording.list(in: recordingsURL).first(where: { $0.url.lastPathComponent == want || $0.url.deletingPathExtension().lastPathComponent == want }) {
                MainActor.assumeIsolated { play(r) }
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
