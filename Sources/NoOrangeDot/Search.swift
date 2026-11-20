import SwiftUI

/// Something the sidebar's search can find: a page, a card, or a setting, and where it lives.
struct SearchItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// Where it is, shown under the title.
    let place: String
    let tab: EditorTab
    var keywords: [String] = []
    /// Where it jumps to, when that differs from `id`.
    var anchor: String?

    var target: String { anchor ?? id }

    /// Everything on the three pages, plus the saved presets.
    @MainActor static func all(_ engine: Engine) -> [SearchItem] {
        var items: [SearchItem] = [
            .init(id: "page.sound", title: "Sound", place: "Page", tab: .sound),
            .init(id: "page.recordings", title: "Recordings", place: "Page", tab: .recordings, keywords: ["takes", "player"]),
            .init(id: "page.settings", title: "Settings", place: "Page", tab: .settings, keywords: ["preferences"]),

            .init(id: "sound.eq", title: "Equalizer", place: "Sound", tab: .sound, keywords: ["eq", "curve", "bands", "frequency"]),
            .init(id: "sound.eq.voice", title: "See your voice", place: "Sound › Equalizer", tab: .sound, keywords: ["spectrum", "analyzer"], anchor: "sound.eq"),
            .init(id: "sound.eq.heat", title: "Heat map", place: "Sound › Equalizer", tab: .sound, keywords: ["spectrum", "history"], anchor: "sound.eq"),
            .init(id: "sound.eq.curves", title: "Earlier curves", place: "Sound › Equalizer", tab: .sound, keywords: ["history", "start from", "reset"], anchor: "sound.eq"),

            .init(id: "sound.tone", title: "Tone", place: "Sound", tab: .sound, keywords: ["simple"]),
            .init(id: "sound.tone.rumble", title: "Rumble", place: "Sound › Tone", tab: .sound, keywords: ["low cut", "high pass", "hum"]),
            .init(id: "sound.tone.weight", title: "Weight", place: "Sound › Tone", tab: .sound, keywords: ["bass", "low", "deeper"]),
            .init(id: "sound.tone.body", title: "Body", place: "Sound › Tone", tab: .sound, keywords: ["fuller", "warmth"]),
            .init(id: "sound.tone.box", title: "Box", place: "Sound › Tone", tab: .sound, keywords: ["boxy", "mud"]),
            .init(id: "sound.tone.words", title: "Words", place: "Sound › Tone", tab: .sound, keywords: ["clarity", "presence", "clearer"]),
            .init(id: "sound.tone.edge", title: "Edge", place: "Sound › Tone", tab: .sound, keywords: ["bright", "treble", "air"]),

            .init(id: "sound.dynamics", title: "Dynamics", place: "Sound", tab: .sound),
            .init(id: "sound.dynamics.gate", title: "Noise gate", place: "Sound › Dynamics", tab: .sound, keywords: ["background noise", "hiss"]),
            .init(id: "sound.dynamics.comp", title: "Compressor", place: "Sound › Dynamics", tab: .sound, keywords: ["compression", "even out", "loud"]),
            .init(id: "sound.dynamics.deess", title: "De-esser", place: "Sound › Dynamics", tab: .sound, keywords: ["sibilance", "s sounds", "deesser"]),
            .init(id: "sound.dynamics.limiter", title: "Limiter", place: "Sound › Dynamics", tab: .sound, keywords: ["peaks", "clipping"]),

            .init(id: "sound.voice", title: "Voice level", place: "Sound", tab: .sound, keywords: ["meter", "loudness"]),
            .init(id: "sound.voice.check", title: "Check My Voice", place: "Sound › Voice level", tab: .sound, keywords: ["test", "level"], anchor: "sound.voice"),
            .init(id: "sound.voice.reference", title: "Reference voice", place: "Sound › Voice level", tab: .sound, keywords: ["sample", "compare"], anchor: "sound.voice"),
            .init(id: "sound.voice.output", title: "Output level", place: "Sound › Voice level", tab: .sound, keywords: ["volume", "gain"], anchor: "sound.voice"),

            .init(id: "sound.presets", title: "Presets", place: "Sound", tab: .sound, keywords: ["saved sounds"]),

            .init(id: "settings.priority", title: "Microphone priority", place: "Settings", tab: .settings, keywords: ["order", "automatic", "fallback"]),
            .init(id: "settings.name", title: "Name apps see", place: "Settings › Microphone", tab: .settings, keywords: ["rename", "mic name"]),
            .init(id: "settings.input", title: "Real microphone", place: "Settings › Microphone", tab: .settings, keywords: ["input", "device"]),
            .init(id: "settings.system", title: "Use as the Mac's microphone", place: "Settings › Microphone", tab: .settings, keywords: ["system", "default input", "airpods"]),
            .init(id: "settings.folder", title: "Recordings folder", place: "Settings › Recordings", tab: .settings, keywords: ["location", "save", "finder"]),
            .init(id: "settings.shortcuts", title: "Shortcuts", place: "Settings", tab: .settings, keywords: ["keyboard", "hotkey", "mute", "record"]),
            .init(id: "settings.icon", title: "App icon", place: "Settings › App", tab: .settings, keywords: ["paint", "carbon"]),
            .init(id: "settings.dock", title: "Show in Dock", place: "Settings › App", tab: .settings, keywords: ["menu bar"]),
            .init(id: "settings.login", title: "Start at login", place: "Settings › App", tab: .settings, keywords: ["launch", "startup"]),
            .init(id: "settings.version", title: "Check for updates", place: "Settings › Updates", tab: .settings, keywords: ["version", "update"]),
            .init(id: "settings.autoUpdate", title: "Check automatically", place: "Settings › Updates", tab: .settings, keywords: ["updates"]),
            .init(id: "settings.cli", title: "Command-line tool", place: "Settings › Automation", tab: .settings, keywords: ["cli", "nod", "terminal", "script"]),
        ]
        if engine.micGain != nil {
            items.append(.init(id: "settings.gain", title: "Mic gain", place: "Settings › Microphone", tab: .settings, keywords: ["input level", "sensitivity"]))
            items.append(.init(id: "settings.lockGain", title: "Lock gain", place: "Settings › Microphone", tab: .settings, keywords: ["hold gain"]))
        }
        // Presets lead to the Presets card, where clicking one uses it.
        items += engine.presets.map { .init(id: "preset.\($0.id)", title: $0.name, place: "Preset", tab: .sound, anchor: "sound.presets") }
        return items
    }

    /// Items where every word of the query starts a word of the title or keywords, best first: titles that start
    /// with the query, then titles that hold every word, then keyword matches. "mic" finds Mic gain, not Dynamics.
    static func matches(_ query: String, in items: [SearchItem]) -> [SearchItem] {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let scored: [(SearchItem, Int, Int)] = items.enumerated().compactMap { i, item in
            let title = fold(item.title)
            let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let keywordWords = item.keywords.flatMap { fold($0).split(separator: " ").map(String.init) }
            let found = words.allSatisfy { w in titleWords.contains { $0.hasPrefix(w) } || keywordWords.contains { $0.hasPrefix(w) } }
            guard found else { return nil }
            let whole = words.joined(separator: " ")
            let rank = title.hasPrefix(whole) ? 0 : words.allSatisfy { w in titleWords.contains { $0.hasPrefix(w) } } ? 1 : 2
            return (item, rank, i)
        }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }
}

// MARK: Showing what was found

private struct SearchTargetKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The anchor the search just jumped to. It lights up for a moment.
    var searchTarget: String? {
        get { self[SearchTargetKey.self] }
        set { self[SearchTargetKey.self] = newValue }
    }
}

extension EditorTab {
    var tileColors: [Color] {
        switch self {
        case .sound: return [Color(red: 0.56, green: 0.45, blue: 1.0), Color(red: 0.40, green: 0.28, blue: 0.92)]
        case .recordings: return [Color(red: 1.0, green: 0.42, blue: 0.38), Color(red: 0.88, green: 0.20, blue: 0.20)]
        case .settings: return [Color(white: 0.64), Color(white: 0.46)]
        }
    }
    var tileSymbol: String { self == .sound ? "slider.vertical.3" : self == .recordings ? "waveform" : "gearshape.fill" }
}

/// A page's icon: a white symbol on a small coloured tile.
struct SidebarIcon: View {
    let tab: EditorTab
    var size: CGFloat = 24
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: tab.tileSymbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(shape.fill(LinearGradient(colors: tab.tileColors, startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct SearchAnchor: ViewModifier {
    let id: String
    var radius: CGFloat
    var inset: CGFloat
    @Environment(\.searchTarget) private var target

    func body(content: Content) -> some View {
        let lit = target == id
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .id(id)
            .overlay(
                shape.fill(Color.accentColor.opacity(0.08))
                    .overlay(shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2))
                    .padding(inset)
                    .opacity(lit ? 1 : 0)
                    .animation(lit ? .easeOut(duration: 0.15) : .easeOut(duration: 0.8), value: lit)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Where the search can jump to. A card is outlined at its own corners; a row inside one uses `row`.
    func searchAnchor(_ id: String, radius: CGFloat = Surface.radius, inset: CGFloat = 0) -> some View {
        modifier(SearchAnchor(id: id, radius: radius, inset: inset))
    }

    func searchAnchor(row id: String) -> some View { searchAnchor(id, radius: Surface.radius - 6, inset: 6) }
}

/// The search field at the top of the sidebar.
struct SidebarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        // The glyph sits over the page icons below it, and the text starts where their names do.
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 24)
            TextField("Search", text: $text)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused(focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear").accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 6).padding(.trailing, 11).frame(height: 34)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(focused.wrappedValue ? 0 : 0.07), lineWidth: 1))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(focused.wrappedValue ? 0.55 : 0), lineWidth: 2))
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
        .onExitCommand { text = ""; focused.wrappedValue = false }
        .help("Search settings and controls (⌘F)")
    }
}

/// Where the window buttons sit, in points from the window's top-left corner.
struct WindowChrome: Equatable {
    var buttonsMaxX: CGFloat = 70
    var buttonsMidY: CGFloat = 14
}

/// Reads where the window buttons are, so the app's name can sit level with them.
struct WindowChromeReader: NSViewRepresentable {
    @Binding var chrome: WindowChrome

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.report = { new in if chrome != new { chrome = new } }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var report: (WindowChrome) -> Void = { _ in }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measure() }
        override func layout() { super.layout(); measure() }

        private func measure() {
            guard let window, let zoom = window.standardWindowButton(.zoomButton), let bar = zoom.superview else { return }
            let frame = bar.convert(zoom.frame, to: nil)
            let chrome = WindowChrome(buttonsMaxX: frame.maxX, buttonsMidY: window.frame.height - frame.midY)
            DispatchQueue.main.async { [report] in report(chrome) }
        }
    }
}
