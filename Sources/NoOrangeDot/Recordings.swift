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
        VStack(alignment: .leading, spacing: 12) {
            HStack { RecordingsFolderMenu(); Spacer() }
            Card {
                if engine.recordings.isEmpty {
                    HStack(spacing: 4) {
                        ArtworkView(art: .emptyRecordings, tint: Artwork.tint(engine.appIcon)).padding(.leading, 14)
                        Row(title: "Nothing here yet", caption: "Press Record and say a few sentences.") { EmptyView() }
                    }
                } else {
                    ForEach(Self.days(engine.recordings), id: \.title) { day in
                        Text(day.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                        ForEach(Array(day.takes.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider().padding(.leading, 62) }
                            RecordingRow(take: r)
                        }
                    }
                    Spacer().frame(height: 6)
                }
            }
        }
        .onAppear { engine.refreshRecordings() }
    }

    /// Takes under a heading for each day, newest first: "Today", "Yesterday", "Tuesday, Nov 17".
    static func days(_ takes: [Recording]) -> [(title: String, takes: [Recording])] {
        var out: [(title: String, takes: [Recording])] = []
        for take in takes {
            let title = day(take.date)
            if out.last?.title == title { out[out.count - 1].takes.append(take) } else { out.append((title, [take])) }
        }
        return out
    }

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return sameYear ? date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                        : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// Which folder the list shows and new takes go to: the default, recent ones, or another.
struct RecordingsFolderMenu: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let current = engine.recordingsFolder
        let others = engine.recentRecordingFolders.filter { $0 != current }
        Menu {
            Button { engine.useRecordingsFolder("") } label: { check(current.isEmpty, "No Orange Dot (Default)") }
            if !current.isEmpty { Button {} label: { check(true, Self.name(current)) } }
            ForEach(others, id: \.self) { path in
                Button { engine.useRecordingsFolder(path) } label: { check(false, Self.name(path)) }
            }
            Divider()
            Button("Choose Folder…") { engine.chooseRecordingsFolder() }
            Button("Show in Finder") { NSWorkspace.shared.open(engine.recordingsURL) }
            if !others.isEmpty {
                Menu("Remove from List") {
                    ForEach(others, id: \.self) { path in Button(Self.name(path)) { engine.forgetRecordingsFolder(path) } }
                }
            }
            Divider()
            Button("Move All to Trash…", role: .destructive) { clear() }.disabled(engine.recordings.isEmpty)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(engine.recordingsURL.lastPathComponent).font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help((engine.recordingsURL.path as NSString).abbreviatingWithTildeInPath)
        .accessibilityLabel("Recordings folder, \(engine.recordingsURL.lastPathComponent)")
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    static func name(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent }

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

/// One take under its day: play, the time, its length, and Show in Finder and Trash on hover or right-click.
struct RecordingRow: View {
    @EnvironmentObject var engine: Engine
    let take: Recording
    @State private var hovering = false

    /// A file the app named by its time adds nothing beside the time. A clip or a renamed file shows its name.
    private var name: String? {
        let name = take.url.deletingPathExtension().lastPathComponent
        return name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil ? nil : name
    }

    var body: some View {
        let selected = engine.playerRecording?.url == take.url
        let loaded = engine.auditioning == take.url
        let playing = loaded && !engine.playerPaused
        HStack(spacing: 12) {
            Button { if loaded { engine.playerPaused.toggle() } else { engine.play(take) } } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(engine.recording)
            .help(playing ? "Pause" : "Play").accessibilityLabel(playing ? "Pause" : "Play \(Recording.friendly(take.date))")
            Button { engine.choosePlayerTake(take) } label: {
                HStack(spacing: 10) {
                    Text(take.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 15, weight: selected ? .semibold : .regular))
                    if let name { Text(name).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 8)
                    Text(Recording.clock(take.seconds)).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(Recording.friendly(take.date)) in the player").accessibilityAddTraits(selected ? .isSelected : [])
            HStack(spacing: 2) {
                IconButton(symbol: "folder", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.url]) }
                IconButton(symbol: "trash", label: "Move to Trash") { engine.trash([take]) }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 14).frame(height: 50)
        .background(selected ? Color.accentColor.opacity(0.08) : hovering ? Color.primary.opacity(0.03) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(playing ? "Pause" : "Play") { if loaded { engine.playerPaused.toggle() } else { engine.play(take) } }.disabled(engine.recording)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.url]) }
            Divider()
            Button("Move to Trash") { engine.trash([take]) }
        }
    }
}
