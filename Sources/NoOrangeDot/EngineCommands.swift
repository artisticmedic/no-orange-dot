import AppKit
import Foundation

extension Band {
    static func neighbour(of selected: UUID?, in bands: [Band], step: Int) -> UUID? {
        let order = bands.sorted { $0.freq < $1.freq }
        guard !order.isEmpty else { return nil }
        guard let at = order.firstIndex(where: { $0.id == selected }) else { return (step > 0 ? order.first : order.last)?.id }
        return order[(at + step + order.count) % order.count].id
    }
}

extension Engine {
    var selectedInput: String? {
        let available = inputs.map(\.uid)
        return MicrophonePriority.select(order: micOrder, available: available, previouslyAvailable: available, manual: manualInputUID, current: inputUID)
    }

    /// Connected microphones outside the priority list. An unplugged one can't stand in, so it isn't listed.
    var otherMicUIDs: [String] {
        Set(inputs.map(\.uid)).filter { !$0.isEmpty && !micOrder.contains($0) }.sorted {
            let a = micName(for: $0) ?? $0, b = micName(for: $1) ?? $1
            return a == b ? $0 < $1 : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func chooseInput(_ uid: String) {
        guard inputs.contains(where: { $0.uid == uid }) else { return }
        manualInputUID = uid
        inputUID = uid
    }

    func includeMic(_ uid: String, included: Bool) {
        var s = settings
        s.includeMic(uid, included: included)
        micOrder = s.micOrder
        if (selectedInput ?? "") != inputUID { rebuild() }
    }

    func micName(for uid: String) -> String? { seenNames[uid] ?? mics[uid].map(\.name).flatMap { $0.isEmpty ? nil : $0 } }

    /// Swaps a microphone with the listed one above or below it, then switches if a different one now comes first.
    func moveMic(_ uid: String, past other: String) {
        guard let a = micOrder.firstIndex(of: uid), let b = micOrder.firstIndex(of: other) else { return }
        micOrder.swapAt(a, b)
        if (selectedInput ?? "") != inputUID { rebuild() }
    }

    static let heatMapKey = "heatMap"
    static var heatMap: Bool {
        get { UserDefaults.standard.object(forKey: heatMapKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: heatMapKey) }
    }

    func shortcut(for id: String) -> String { settings.shortcut(for: id) }

    func setShortcut(_ text: String, for id: String) {
        if id == MenuCommand.mute { muteShortcut = text }
        else if id == MenuCommand.record { recordShortcut = text }
        else { shortcuts[id] = text.isEmpty ? nil : text }
    }

    var selectedBandIndex: Int? { bands.firstIndex { $0.id == selectedBand } }

    func addBand() {
        guard bands.count < DSPChain.maxBands else { return }
        let b = Band(type: .bell, freq: 1000, gainDB: 0, q: 1)
        bands.append(b)
        selectedBand = b.id
    }

    func removeSelectedBand() {
        guard let i = selectedBandIndex else { return }
        bands.remove(at: i)
    }

    func selectBand(step: Int) {
        selectedBand = Band.neighbour(of: selectedBand, in: bands, step: step)
    }

    func editSelectedBand(_ change: (inout Band) -> Void) {
        guard let i = selectedBandIndex else { return }
        var b = bands[i]
        change(&b)
        b.freq = min(max(b.freq, 20), 20000)
        b.gainDB = min(max(b.gainDB, -18), 18)
        b.q = min(max(b.q, 0.2), 10)
        bands[i] = b
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = recordingsURL
        panel.prompt = "Use This Folder"
        panel.message = "New recordings are saved here, and the list shows what is in it."
        if panel.runModal() == .OK, let url = panel.url { recordingsFolder = url.path }
    }

    @MainActor func play(_ r: Recording) {
        guard !recording else { note("Stop recording to play a take."); return }
        Playback.shared.stop()
        if r.raw != nil { startAudition(r) } else { stopAudition(); Playback.shared.toggle(r.url) }
    }

    @MainActor func stopPlaying() { stopAudition(); Playback.shared.stop() }

    func note(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.notice == text { self?.notice = nil } }
    }
}
