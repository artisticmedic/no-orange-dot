import AVFoundation
import SwiftUI

/// The one player for recordings, pinned under the page on Sound and Recordings.
struct PlayerBar: View {
    @EnvironmentObject var engine: Engine
    @FocusState private var focused: Bool
    @State private var peaks: [Float] = []

    var body: some View {
        if let take = engine.playerRecording {
            let loaded = engine.auditioning == take.url
            let playing = loaded && !engine.playerPaused
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    IconButton(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play") { focused = true; engine.togglePlay() }
                        .disabled(engine.recording)
                    VStack(alignment: .leading, spacing: 2) {
                        takeMenu(take)
                        Text(take.raw != nil ? "Through your current sound" : "As saved")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Live(engine.meters) { _ in
                        Text("\(Recording.clock(engine.playheadSeconds)) / \(Recording.clock(take.seconds))")
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { engine.auditionLoop.toggle() } label: { Label("Loop", systemImage: "repeat") }
                        .buttonStyle(TopBarButtonStyle(active: engine.auditionLoop, tint: .accentColor))
                        .help(engine.selection == nil ? "Repeat the whole recording" : "Repeat the selection")
                        .accessibilityAddTraits(engine.auditionLoop ? .isSelected : [])
                    if loaded {
                        IconButton(symbol: "stop.fill", label: "Stop") { engine.stopPlaying() }
                    }
                }
                WaveformView(duration: take.seconds, peaks: peaks) { focused = true }
                    .frame(height: 46)
                selectionRow
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 12)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in key(press) }
            .task(id: take.url) { peaks = await Self.peaks(for: take.raw ?? take.url) }
            .help("Space plays or pauses. Arrow keys move the playhead a second, or five with Shift. I and O set the selection's ends, L turns looping on or off, Escape clears the selection.")
        }
    }

    private func takeMenu(_ take: Recording) -> some View {
        Menu {
            ForEach(engine.recordings.prefix(30)) { r in
                Button { engine.choosePlayerTake(r) } label: {
                    let text = "\(Recording.friendly(r.date))  ·  \(Recording.clock(r.seconds))  ·  \(r.url.deletingPathExtension().lastPathComponent)"
                    if r.url == take.url { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(Recording.friendly(take.date)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Choose a recording").accessibilityLabel("Recording in the player")
    }

    @ViewBuilder private var selectionRow: some View {
        if let s = engine.selection {
            HStack(spacing: 8) {
                Text("Selection \(Self.time(s.lowerBound)) – \(Self.time(s.upperBound))  ·  \(String(format: "%.1f s", s.upperBound - s.lowerBound))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Save as New Recording") { engine.saveSelection() }.buttonStyle(PillButtonStyle()).disabled(engine.recording)
                    .help("Saves this part as its own recording. The original stays as it is.")
                Button("Clear") { engine.setSelection(nil) }.buttonStyle(PillButtonStyle())
            }
        } else {
            Text("Click to move the playhead. Drag across the waveform to select a part to loop or save.")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let step = press.modifiers.contains(.shift) ? 5.0 : 1.0
        switch press.key {
        case .space: engine.togglePlay()
        case .leftArrow: engine.seek(to: engine.playheadSeconds - step)
        case .rightArrow: engine.seek(to: engine.playheadSeconds + step)
        case .escape: engine.setSelection(nil)
        default:
            let now = engine.playheadSeconds, total = engine.playerRecording?.seconds ?? 0
            switch press.characters.lowercased() {
            case "i": engine.setSelection(now...max(engine.selection?.upperBound ?? total, now + 0.05))
            case "o": engine.setSelection(min(engine.selection?.lowerBound ?? 0, now - 0.05)...now)
            case "l": engine.auditionLoop.toggle()
            default: return .ignored
            }
        }
        return .handled
    }

    static func time(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }

    private static var cache: [URL: [Float]] = [:]

    /// The loudest sample in each slice of the file, read off the main thread.
    static func peaks(for url: URL) async -> [Float] {
        if let hit = await MainActor.run(body: { cache[url] }) { return hit }
        let result = await Task.detached(priority: .userInitiated) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url), file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return [] }
            return AuditionPlayer.peaks(data[0], count: Int(buffer.frameLength))
        }.value
        await MainActor.run { cache[url] = result }
        return result
    }
}

/// The recording drawn as a waveform. Click to seek, drag the playhead to scrub, drag across to select,
/// drag a selection's edge to move it.
struct WaveformView: View {
    @EnvironmentObject var engine: Engine
    let duration: Double
    let peaks: [Float]
    var onTouch: () -> Void = {}
    @State private var mode: Mode?

    private enum Mode { case start, end, playhead, pending(Double), select(Double) }

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1), h = g.size.height
            Live(engine.meters) { _ in
                let head = engine.playheadSeconds
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Surface.plot))
                    let sel = engine.selection
                    if let sel {
                        let r = CGRect(x: x(sel.lowerBound, w), y: 0, width: x(sel.upperBound, w) - x(sel.lowerBound, w), height: h)
                        ctx.fill(Path(r), with: .color(.accentColor.opacity(0.14)))
                    }
                    let top = max(peaks.max() ?? 0, 0.05)
                    let barW = w / CGFloat(max(peaks.count, 1))
                    for (i, p) in peaks.enumerated() {
                        let t = Double(i) / Double(max(peaks.count, 1)) * duration
                        let inside = sel.map { $0.contains(t) } ?? false
                        let bh = max(1, CGFloat(p / top) * (h - 8))
                        let r = CGRect(x: CGFloat(i) * barW, y: (h - bh) / 2, width: max(barW - 0.5, 0.5), height: bh)
                        ctx.fill(Path(r), with: .color(inside ? .accentColor.opacity(0.85) : .primary.opacity(0.32)))
                    }
                    if let sel {
                        for edge in [sel.lowerBound, sel.upperBound] {
                            let ex = x(edge, w)
                            ctx.fill(Path(CGRect(x: ex - 1, y: 0, width: 2, height: h)), with: .color(.accentColor))
                            ctx.fill(Path(roundedRect: CGRect(x: ex - 4, y: 0, width: 8, height: 10), cornerRadius: 2), with: .color(.accentColor))
                        }
                    }
                    ctx.fill(Path(CGRect(x: x(head, w) - 0.75, y: 0, width: 1.5, height: h)), with: .color(.primary))
                }
                .accessibilityElement()
                .accessibilityLabel("Recording waveform")
                .accessibilityValue("\(Recording.clock(head)) of \(Recording.clock(duration))")
                .accessibilityAdjustableAction { direction in
                    engine.seek(to: head + (direction == .increment ? 1 : -1))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in changed(v, w) }.onEnded { v in ended(v, w) })
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { duration > 0 ? CGFloat(t / duration) * w : 0 }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { Double(min(max(x / w, 0), 1)) * duration }

    private func changed(_ v: DragGesture.Value, _ w: CGFloat) {
        let now = t(v.location.x, w)
        guard let current = mode else {
            onTouch()
            let x0 = v.startLocation.x
            if let s = engine.selection, abs(x0 - x(s.lowerBound, w)) < 7 { mode = .start }
            else if let s = engine.selection, abs(x0 - x(s.upperBound, w)) < 7 { mode = .end }
            else if abs(x0 - x(engine.playheadSeconds, w)) < 5 { mode = .playhead }
            else { mode = .pending(t(x0, w)) }
            return
        }
        switch current {
        case .start: if let s = engine.selection { engine.setSelection(min(now, s.upperBound - 0.05)...s.upperBound) }
        case .end: if let s = engine.selection { engine.setSelection(s.lowerBound...max(now, s.lowerBound + 0.05)) }
        case .playhead: engine.seek(to: now)
        case .pending(let t0):
            if abs(v.translation.width) > 3 { mode = .select(t0); engine.setSelection(min(t0, now)...max(t0, now)) }
        case .select(let t0): engine.setSelection(min(t0, now)...max(t0, now))
        }
    }

    private func ended(_ v: DragGesture.Value, _ w: CGFloat) {
        switch mode {
        case .pending(let t0): engine.seek(to: t0)
        // A new selection plays from its start when something is already playing.
        case .select, .start: if let s = engine.selection, engine.auditioning != nil { engine.seek(to: s.lowerBound) }
        default: break
        }
        mode = nil
    }
}
