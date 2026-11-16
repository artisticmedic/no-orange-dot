import AppKit
import Foundation

extension Band {
    /// The band one step up or down in frequency from the selected one, wrapping at the ends.
    /// With nothing selected, a step up starts at the lowest band and a step down at the highest.
    static func neighbour(of selected: UUID?, in bands: [Band], step: Int) -> UUID? {
        let order = bands.sorted { $0.freq < $1.freq }
        guard !order.isEmpty else { return nil }
        guard let at = order.firstIndex(where: { $0.id == selected }) else { return (step > 0 ? order.first : order.last)?.id }
        return order[(at + step + order.count) % order.count].id
    }
}

/// Actions the window and the menus share.
extension Engine {
    static let heatMapKey = "heatMap"
    static var heatMap: Bool {
        get { UserDefaults.standard.object(forKey: heatMapKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: heatMapKey) }
    }

    /// The shortcut the user gave a command, as text. Empty when it has none.
    func shortcut(for id: String) -> String {
        id == MenuCommand.mute ? muteShortcut : id == MenuCommand.record ? recordShortcut : shortcuts[id] ?? ""
    }

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
        selectedBand = nil
        bands.remove(at: i)
    }

    /// Moves the selection along the bands from low to high, wrapping at the ends.
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

    /// Plays a recording: through the EQ when its raw take was kept, as saved otherwise.
    @MainActor func play(_ r: Recording) {
        Playback.shared.stop()
        if r.raw != nil { startAudition(r) } else { stopAudition(); Playback.shared.toggle(r.url) }
    }

    @MainActor func stopPlaying() { stopAudition(); Playback.shared.stop() }
}
