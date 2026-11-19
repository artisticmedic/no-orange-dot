import AVFoundation
import AppKit
import SwiftUI

struct Recording: Identifiable, Equatable {
    let url: URL
    let date: Date
    let seconds: Double
    /// The same take before any processing, when the app saved one.
    var raw: URL?
    var id: URL { url }

    /// Raw takes are hidden files beside the recording: ".<name>.raw.wav".
    static func rawURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).raw.wav")
    }

    /// Audio files in a folder, newest first.
    static func list(in folder: URL) -> [Recording] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files.filter { ["wav", "aif", "aiff", "m4a", "mp3", "caf"].contains($0.pathExtension.lowercased()) }.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var seconds = 0.0
            if let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 { seconds = Double(f.length) / f.fileFormat.sampleRate }
            let raw = rawURL(for: url)
            return Recording(url: url, date: date, seconds: seconds, raw: FileManager.default.fileExists(atPath: raw.path) ? raw : nil)
        }.sorted { $0.date > $1.date }
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
    /// "Today, 7:17 PM", "Yesterday, 9:02 AM", or the date for anything older.
    static func friendly(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Plays one file through the Mac's output, for the automatic EQ's before-and-after.
@MainActor
final class Playback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing: URL?
    private var player: AVAudioPlayer?
    @Published var voice = VoiceLevel.Reading(averageDB: -100, peakDB: -100)
    private var meterTimer: Timer?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        ReferenceVoice.shared.stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.isMeteringEnabled = true
        p.delegate = self
        player = p
        playing = url
        p.play()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeter() }
        }
    }

    func stop() {
        meterTimer?.invalidate(); meterTimer = nil
        player?.stop(); player = nil; playing = nil
        voice = VoiceLevel.Reading(averageDB: -100, peakDB: -100)
    }

    private func updateMeter() {
        guard let player else { return }
        player.updateMeters()
        var power = 0.0, peak = -100.0
        for channel in 0..<player.numberOfChannels {
            power += pow(10, Double(player.averagePower(forChannel: channel)) / 10)
            peak = max(peak, Double(player.peakPower(forChannel: channel)))
        }
        voice = VoiceLevel.Reading(averageDB: 10 * log10(max(power / Double(player.numberOfChannels), 1e-10)), peakDB: peak)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }
}

struct RecordingsView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Card {
            CardHeader(title: engine.recordings.isEmpty ? "Recordings" : "Recordings (\(engine.recordings.count))",
                       caption: "Saved in \((engine.recordingsURL.path as NSString).abbreviatingWithTildeInPath). Choose one to open it in the player below.") {
                HStack(spacing: 8) {
                    Button("Open Folder") { NSWorkspace.shared.open(engine.recordingsURL) }.buttonStyle(PillButtonStyle())
                    if !engine.recordings.isEmpty {
                        Button("Delete All…") { clear() }.buttonStyle(PillButtonStyle())
                    }
                }
            }
            if engine.recordings.isEmpty {
                RowDivider()
                HStack(spacing: 4) {
                    ArtworkView(art: .emptyRecordings, tint: Artwork.tint(engine.appIcon)).padding(.leading, 14)
                    Row(title: "Nothing here yet", caption: "Press Record and say a few sentences.") { EmptyView() }
                }
            } else {
                ForEach(engine.recordings) { r in
                    RowDivider()
                    row(r)
                }
            }
        }
        .onAppear { engine.refreshRecordings() }
    }

    private func row(_ r: Recording) -> some View {
        let selected = engine.playerRecording?.url == r.url
        let loaded = engine.auditioning == r.url
        let playing = loaded && !engine.playerPaused
        return HStack(spacing: 0) {
            Button { engine.choosePlayerTake(r) } label: {
                HStack(spacing: 4) {
                    ArtworkView(art: .take, tint: Artwork.tint(engine.appIcon)).padding(.leading, 14)
                    Row(title: Recording.friendly(r.date),
                        caption: "\(Recording.clock(r.seconds))  ·  \(r.url.lastPathComponent)  ·  \(r.raw != nil ? "plays through your current sound" : "plays as saved")") { EmptyView() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(Recording.friendly(r.date)) in the player").accessibilityAddTraits(selected ? .isSelected : [])
            HStack(spacing: 2) {
                IconButton(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play") {
                    if loaded { engine.playerPaused.toggle() } else { engine.play(r) }
                }
                .disabled(engine.recording)
                IconButton(symbol: "folder", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                IconButton(symbol: "trash", label: "Move to Trash") { engine.trash([r]) }
            }
            .padding(.trailing, 8)
        }
        .background(selected ? Color.primary.opacity(0.05) : .clear)
    }

    private func clear() {
        let alert = NSAlert()
        let n = engine.recordings.count
        alert.messageText = "Move \(n == 1 ? "this recording" : "all \(n) recordings") to the Trash?"
        alert.informativeText = "You can put them back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { engine.stopPlaying(); engine.trash(engine.recordings) }
    }
}
