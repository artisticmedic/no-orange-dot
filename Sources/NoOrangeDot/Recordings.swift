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

/// Plays one recording at a time through the Mac's output.
@MainActor
final class Playback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        player = p
        playing = url
        p.play()
    }

    func stop() { player?.stop(); player = nil; playing = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}

struct RecordingsView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var playback = Playback()

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                SectionLabel(text: "Folder")
                Card {
                    Row(title: (engine.recordingsURL.path as NSString).abbreviatingWithTildeInPath, caption: "New recordings go here.") {
                        HStack(spacing: 8) {
                            Button("Open") { NSWorkspace.shared.open(engine.recordingsURL) }.buttonStyle(PillButtonStyle())
                            Button("Change…") { choose() }.buttonStyle(PillButtonStyle())
                        }
                    }
                }
            }
            VStack(spacing: 8) {
                HStack {
                    SectionLabel(text: engine.recordings.isEmpty ? "Recordings" : "Recordings (\(engine.recordings.count))")
                    if !engine.recordings.isEmpty {
                        Button("Delete All…") { clear() }.buttonStyle(PillButtonStyle())
                    }
                }
                Card {
                    if engine.recordings.isEmpty {
                        HStack(spacing: 4) {
                            ArtworkView(art: .emptyRecordings, tint: Artwork.tint(engine.appIcon)).padding(.leading, 14)
                            Row(title: "Nothing here yet", caption: "Press Record and say a few sentences.") { EmptyView() }
                        }
                    } else {
                        ForEach(Array(engine.recordings.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { RowDivider() }
                            row(r)
                        }
                    }
                }
            }
        }
        .onAppear { engine.refreshRecordings() }
        .onDisappear { playback.stop() }
    }

    private func row(_ r: Recording) -> some View {
        let throughEQ = r.raw != nil
        let isPlaying = throughEQ ? engine.auditioning == r.url : playback.playing == r.url
        return HStack(spacing: 0) {
          ArtworkView(art: .take, tint: Artwork.tint(engine.appIcon)).padding(.leading, 14)
          Row(title: Recording.friendly(r.date),
                   caption: "\(Recording.clock(r.seconds))  ·  \(r.url.lastPathComponent)\(throughEQ ? "  ·  plays through the EQ" : "")") {
            HStack(spacing: 2) {
                IconButton(symbol: isPlaying ? "stop.fill" : "play.fill", label: isPlaying ? "Stop" : throughEQ ? "Play through the EQ" : "Play") {
                    playback.stop()
                    if throughEQ { if isPlaying { engine.stopAudition() } else { engine.startAudition(r) } }
                    else { engine.stopAudition(); if !isPlaying { playback.toggle(r.url) } }
                }
                IconButton(symbol: "folder", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                IconButton(symbol: "trash", label: "Move to Trash") {
                    if playback.playing == r.url { playback.stop() }
                    engine.trash([r])
                }
            }
          }
        }
        .background(isPlaying ? Color.primary.opacity(0.05) : .clear)
    }

    private func clear() {
        let alert = NSAlert()
        let n = engine.recordings.count
        alert.messageText = "Move \(n == 1 ? "this recording" : "all \(n) recordings") to the Trash?"
        alert.informativeText = "You can put them back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { playback.stop(); engine.trash(engine.recordings) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = engine.recordingsURL
        panel.prompt = "Use This Folder"
        panel.message = "New recordings are saved here, and the list shows what is in it."
        if panel.runModal() == .OK, let url = panel.url { engine.recordingsFolder = url.path }
    }
}

/// Shown under the tabs while a raw take is playing: the same words on repeat while the EQ is changed.
struct AuditionBar: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if let url = engine.auditioning {
            Card {
                HStack(spacing: 12) {
                    IconButton(symbol: "stop.fill", label: "Stop") { engine.stopAudition() }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Playing \(url.deletingPathExtension().lastPathComponent)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text("Same take, on repeat. Hear your EQ changes.").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ProgressView(value: engine.auditionProgress).controlSize(.small)
                    }
                    Toggle("Loop", isOn: $engine.auditionLoop).toggleStyle(.switch)
                    Toggle("EQ", isOn: Binding(get: { !engine.bypass }, set: { engine.bypass = !$0 })).toggleStyle(.switch)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
    }
}
