import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // Run as `nod`, every argument is a command, so a typo prints an error and never starts a second copy of the app.
        let asTool = (CommandLine.arguments.first as NSString?)?.lastPathComponent == "nod"
        if asTool || args.first.map(CLI.verbs.contains) == true { exit(CLI.run(args)) }
        if let i = args.firstIndex(of: "--icon"), args.count > i + 1 {
            exit(MainActor.assumeIsolated {
                let image = AppDelegate.dockIcon()
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: args[i + 1]))) != nil else { return Int32(1) }
                return Int32(0)
            })
        }
        if let i = args.firstIndex(of: "--render"), args.count > i + 1 { exit(MainActor.assumeIsolated { Render.run(directory: args[i + 1], sample: args.count > i + 2 ? args[i + 2] : nil) }) }
        let app = NSApplication.shared
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = Engine()
    private var item: NSStatusItem!
    private var panel: MenuPanelController!
    private var editor: NSWindow?
    private var menus: MainMenu!
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        panel = MenuPanelController(engine: engine) { [weak self] in self?.perform($0) }
        watch = engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in MainActor.assumeIsolated { self?.updateIcon(); self?.applyDockPolicy(); self?.applyShortcuts(); self?.menus?.refresh(); self?.applyAppIcon(); self?.applyUpdater() } }
        updateIcon()
        DistributedNotificationCenter.default().addObserver(forName: Command.name, object: nil, queue: .main) { [weak self] note in
            guard let verb = note.object as? String else { return }
            MainActor.assumeIsolated {
                if verb == "open-editor" { self?.openEditor() } else { self?.engine.handle(command: verb) }
            }
        }
        menus = MainMenu(engine: engine) { [weak self] in self?.openEditor() }
        menus.install()
        applyAppIcon()
        applyDockPolicy()
        applyShortcuts()
        applyUpdater()
        Updater.shared.checkIfDue()
        // Opened by hand, show the window. Started at login, stay in the menu bar until asked.
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin, !CommandLine.arguments.contains("--quiet") { openEditor() }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.toggle() } }
        if CommandLine.arguments.contains("--editor") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openEditor() } }
    }

    func applicationWillTerminate(_ note: Notification) { engine.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon, or opening the app again, brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openEditor()
        return false
    }

    /// Stand-in Dock icon until there is a drawn one: the menu bar mark on a dark tile.
    static func dockIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { _ in
            let tile = NSRect(x: 50, y: 50, width: 412, height: 412)
            let path = NSBezierPath(roundedRect: tile, xRadius: 92, yRadius: 92)
            NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))?.draw(in: path, angle: -90)
            let mark = AppMark.image(.eclipse, .idle, scale: 14)
            let white = NSImage(size: mark.size, flipped: false) { r in
                mark.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let side: CGFloat = 250
            white.draw(in: NSRect(x: 256 - side / 2, y: 256 - side / 2, width: side, height: side))
            return true
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        panel.toggle(relativeTo: button)
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .mute: engine.muted.toggle()
        case .record: engine.toggleRecording()
        case .equalizer: engine.bypass.toggle()
        case .system: engine.setSystemMicrophone(!engine.isSystemMicrophone)
        case .editor: openEditor()
        case .quit: NSApp.terminate(nil)
        }
    }

    private func openEditor() {
        if editor == nil {
            let host = NSHostingController(rootView: EditorView().environmentObject(engine))
            host.sizingOptions = [.minSize]
            // SwiftUI builds the toolbar and title from the view, so the window looks like any other Mac app's.
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: host)
            // The page's name. The scene bridge changes it when another page is chosen.
            w.title = EditorTab.sound.rawValue
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 980, height: 700))
            w.center()
            w.setFrameAutosaveName("EditorWindow")
            editor = w
        }
        // The window needs a regular app behind it: Dock icon, menus, Command-Tab.
        // With "Show in Dock" off, the app goes back to the menu bar when the window closes.
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.editor?.makeKeyAndOrderFront(nil)
        }
    }

    private var appliedShortcuts = ("\u{0}", "\u{0}")
    private func applyShortcuts() {
        guard appliedShortcuts != (engine.muteShortcut, engine.recordShortcut) else { return }
        appliedShortcuts = (engine.muteShortcut, engine.recordShortcut)
        Hotkeys.shared.registrationFailed = { [weak self] ids in
            guard let self else { return }
            let refused = ids.map { id in
                let text = id == 1 ? self.engine.muteShortcut : self.engine.recordShortcut
                return Shortcut(text)?.display ?? text
            }
            self.engine.error = "macOS wouldn't register \(refused.joined(separator: " or ")). Another app may already use it."
        }
        Hotkeys.shared.replace(with: [
            .init(id: 1, shortcut: Shortcut(engine.muteShortcut), action: { [weak self] in self?.engine.muted.toggle() }),
            .init(id: 2, shortcut: Shortcut(engine.recordShortcut), action: { [weak self] in self?.engine.toggleRecording() }),
        ])
    }

    private var appliedAppIcon = ""
    /// The Dock icon while the app runs. Finder keeps showing the icon built into the app.
    private func applyUpdater() {
        Updater.shared.feed = engine.updateFeed.isEmpty ? UpdateCheck.builtInFeed : engine.updateFeed
        Updater.shared.automatic = engine.autoUpdate
    }

    private func applyAppIcon() {
        guard appliedAppIcon != engine.appIcon else { return }
        appliedAppIcon = engine.appIcon
        NSApp.applicationIconImage = Self.appIcon(engine.appIcon) ?? Self.dockIcon()
    }

    static func appIcon(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: "icon-\(name)", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    private func applyDockPolicy() {
        let want: NSApplication.ActivationPolicy = engine.showInDock || editor?.isVisible == true ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// The live views open the mic, so closing the editor always lets it close again.
    func windowWillClose(_ notification: Notification) {
        engine.cancelMeasure()
        engine.stopPlaying()
        engine.monitoring = false
        engine.checkingVoice = false
        ReferenceVoice.shared.stop()
        DispatchQueue.main.async { [weak self] in self?.applyDockPolicy() }
    }

    private func updateIcon() {
        let image = AppMark.image(AppMark.Style(rawValue: engine.icon) ?? .symbol, engine.markState)
        image.accessibilityDescription = "\(Brand.short): \(engine.statusTitle)"
        item.button?.image = image
    }
}

// MARK: Building blocks

/// The window's surfaces. Cards sit above the page and the EQ plot sits into its card, in both appearances.
enum Surface {
    private static func pair(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    static let page = pair(hex(0xF4F4F5), hex(0x242527))
    static let card = pair(hex(0xFFFFFF), hex(0x2D2F32))
    static let plot = pair(hex(0xFAFAFB), hex(0x232527))
    static let border = pair(hex(0x000000, 0.09), hex(0x3A3C40))
    /// A card's corner. Things inset 10 points inside a card use `radius - 10`, so the corners run parallel.
    static let radius: CGFloat = 14
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Surface.radius, style: .continuous).fill(Surface.card))
            .clipShape(RoundedRectangle(cornerRadius: Surface.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Surface.radius, style: .continuous).strokeBorder(Surface.border, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15))
                if let caption { Text(caption).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// The title at the top of a card, weightier than the rows under it.
struct CardHeader<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let caption { Text(caption).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 36)
        .padding(.leading, 16).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 8)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, caption: String? = nil) { self.init(title: title, caption: caption) { EmptyView() } }
}

/// The Sound page: the editor on the left, level and presets beside it when the window is wide enough.
struct SoundPage: View {
    let wide: Bool
    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) { EQView(graphHeight: 300); ToneCard(); DynamicsView() }
                VStack(spacing: 16) { VoiceCheckCard(); PresetsCard() }.frame(width: 360)
            }
        } else {
            VStack(spacing: 16) { EQView(graphHeight: 260); VoiceCheckCard(); ToneCard(); DynamicsView(); PresetsCard() }
        }
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

struct SliderRow: View {
    let label: String
    let value: String
    @Binding var binding: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 14)).frame(width: 80, alignment: .leading)
            Slider(value: $binding, in: range)
            Text(value).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .accessibilityElement(children: .combine).accessibilityLabel(label).accessibilityValue(value)
    }
}

/// A toggle-like button: tinted while on.
struct ToggleButtonStyle: ButtonStyle {
    var active: Bool
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? tint : Color.primary)
            .padding(.horizontal, 14).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? tint.opacity(0.16) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? tint.opacity(0.35) : Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Every other button with words on it. `prominent` inverts it: label colour fill, background-colour text.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.horizontal, 14).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? Color.primary.opacity(configuration.isPressed ? 0.75 : 0.9) : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A button that is only a symbol, with a target big enough to hit.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(label).accessibilityLabel(label)
    }
}

// MARK: Editor

enum EditorTab: String, CaseIterable, Identifiable {
    case sound = "Sound", recordings = "Recordings", settings = "Settings"
    var id: String { rawValue }
    var symbol: String { self == .sound ? "slider.vertical.3" : self == .recordings ? "waveform" : "gearshape" }
}

/// The full app: a sidebar for the sections and the mic's state, the page on the right.
struct EditorView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var updater = Updater.shared
    @State var tab: EditorTab = .sound
    @State private var width: CGFloat = 0

    private var maxWidth: CGFloat { tab == .sound ? 1180 : tab == .recordings ? 880 : 760 }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    page.padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
                }
                .background(GeometryReader { g in
                    Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
                })
                if engine.driverInstalled, tab != .settings, !engine.recordings.isEmpty {
                    Divider()
                    PlayerBar().frame(maxWidth: maxWidth + 8).frame(maxWidth: .infinity)
                }
            }
            // Under the toolbar too, so the toolbar and the page are one surface.
            .background(Surface.page.ignoresSafeArea())
            .overlay(alignment: .top) { notice }
            .navigationTitle(tab.rawValue)
            .toolbar { toolbar }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { takeRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .showTab)) { _ in takeRequest() }
    }

    private func takeRequest() {
        if let wanted = EditorRequest.tab { tab = wanted; EditorRequest.tab = nil }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { Optional(tab) }, set: { if let t = $0 { tab = t } })) {
            ForEach(EditorTab.allCases) { t in
                Label(t.rawValue, systemImage: t.symbol)
                    .font(.system(size: 14))
                    .badge(t == .recordings ? engine.recordings.count : 0)
                    .tag(t)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The live controls, as keys: the things to reach for while talking.
            VStack(spacing: 8) {
                if engine.driverInstalled {
                    HearMyselfKey()
                    RecordKey()
                    MuteButton(muted: engine.muted) { engine.muted.toggle() }
                }
                status.padding(.top, 4)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    /// What the mic is doing right now. Always on screen, whichever page is open.
    private var status: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                slot.accessibilityHidden(true)
                Text(engine.statusTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.9)
                    .help(engine.statusDetail.isEmpty ? engine.statusTitle : "\(engine.statusTitle). \(engine.statusDetail).")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 12)
            if let note = engine.directUseNote {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            Live(engine.meters) { m in LevelMeter(level: engine.running ? m.level : 0) }.frame(height: 5).opacity(engine.running ? 1 : 0.4)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            Divider()
            micMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Where the icon of the app using the mic goes. Empty and dashed while no app has it.
    @ViewBuilder private var slot: some View {
        if let icon = engine.listenerIcon, engine.running {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(engine.statusColor).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)).offset(x: 2, y: 2)
                }
        } else {
            ZStack {
                ArtworkView(art: .idleSlot).opacity(0.65)
                if engine.recording {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                } else if engine.muted {
                    Image(systemName: "mic.slash.fill").font(.system(size: 13)).foregroundStyle(.orange)
                } else if engine.running {
                    Image(systemName: "mic.fill").font(.system(size: 13)).foregroundStyle(.green)
                }
            }
            .frame(width: 28, height: 28)
        }
    }

    /// Which real microphone is in use, and a menu to change it.
    private var micMenu: some View {
        Menu {
            ForEach(engine.inputs) { input in
                Button { engine.chooseInput(input.uid) } label: {
                    if input.uid == engine.inputUID { Label(input.name, systemImage: "checkmark") } else { Text(input.name) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                Text(engine.inputs.first(where: { $0.uid == engine.inputUID })?.name ?? "Choose a microphone").font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Change the microphone").accessibilityLabel("Microphone")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if engine.driverInstalled {
                if engine.original {
                    Button { engine.original = false } label: { Label("Processing off", systemImage: "exclamationmark.circle") }
                        .labelStyle(.titleAndIcon).foregroundStyle(.orange)
                        .help("Hear Without Processing is on, for apps using the mic too. Click to turn your sound back on.")
                }
                if let take = engine.justSaved, !engine.recording { SavedChip(take: take) { tab = .recordings } }
            }
        }
    }

    @ViewBuilder private var notice: some View {
        if let notice = engine.notice {
            Text(notice).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .padding(.top, 10)
                .transition(.opacity)
        }
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let e = engine.configProblem ?? engine.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
            CrashBanner()
            if !engine.driverInstalled {
                Card { Row(title: "The microphone driver is missing", caption: "Run the installer again. Until it is back, no app can see the microphone.") { EmptyView() } }
            } else {
                switch tab {
                case .sound:
                    SoundPage(wide: width >= 1000)
                case .recordings:
                    RecordingsView()
                case .settings:
                    VStack(spacing: 8) { SectionLabel(text: "Microphone priority"); MicOrderCard() }
                    VStack(spacing: 8) { SectionLabel(text: "Microphone"); general }
                    VStack(spacing: 8) { SectionLabel(text: "Recordings"); recordingsFolder }
                    VStack(spacing: 8) { SectionLabel(text: "Shortcuts"); shortcuts }
                    VStack(spacing: 8) { SectionLabel(text: "App"); app }
                    VStack(spacing: 8) { SectionLabel(text: "Updates"); updates }
                    VStack(spacing: 8) { SectionLabel(text: "Automation"); CLIToolView() }
                }
            }
        }
    }

    private var shortcuts: some View { ShortcutsCard() }

    private var recordingsFolder: some View {
        Card {
            Row(title: (engine.recordingsURL.path as NSString).abbreviatingWithTildeInPath) {
                HStack(spacing: 8) {
                    Button("Open") { NSWorkspace.shared.open(engine.recordingsURL) }.buttonStyle(PillButtonStyle())
                    Button("Change…") { engine.chooseRecordingsFolder() }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private var updates: some View {
        Card {
            Row(title: "Version \(Version.current)", caption: updater.summary) {
                if updater.available != nil {
                    Button("Install…") { updater.install() }.buttonStyle(PillButtonStyle())
                } else {
                    Button(updater.state == .checking ? "Checking…" : "Check Now") { updater.check() }.buttonStyle(PillButtonStyle())
                        .disabled(updater.busy || updater.state == .notSetUp)
                }
            }
            RowDivider()
            Row(title: "Check automatically", caption: "Checks once a day. Nothing about you is sent.") {
                Toggle("Check automatically", isOn: $engine.autoUpdate).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var app: some View {
        Card {
            Row(title: "App icon") {
                HStack(spacing: 10) {
                    ForEach([("paint", "Paint"), ("carbon", "Carbon")], id: \.0) { id, label in
                        Button { engine.appIcon = id } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let image = AppDelegate.appIcon(id) { Image(nsImage: image).resizable().interpolation(.high) } else { Color.primary.opacity(0.1) }
                                }
                                .frame(width: 52, height: 52)
                                Text(label).font(.system(size: 12, weight: engine.appIcon == id ? .semibold : .regular))
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(engine.appIcon == id ? 0.10 : 0)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(engine.appIcon == id ? 0.25 : 0), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(label) icon").accessibilityAddTraits(engine.appIcon == id ? .isSelected : [])
                    }
                }
            }
            RowDivider()
            Row(title: "Show in Dock", caption: "Also while this window is closed.") {
                Toggle("Show in Dock", isOn: $engine.showInDock).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            Row(title: "Start at login") {
                Toggle("Start at login", isOn: Binding(get: { engine.launchAtLogin }, set: { engine.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var general: some View {
        Card {
            MicNameRow()
            RowDivider()
            Row(title: "Real microphone", caption: "Each microphone keeps its own sound.") {
                Menu {
                    ForEach(engine.inputs) { input in
                        Button { engine.chooseInput(input.uid) } label: {
                            if input.uid == engine.inputUID { Label(input.name, systemImage: "checkmark") } else { Text(input.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic").foregroundStyle(.secondary)
                        Text(engine.inputs.first(where: { $0.uid == engine.inputUID })?.name ?? "Choose a microphone").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
                .accessibilityLabel("Real microphone")
            }
            if let g = engine.micGain {
                RowDivider()
                Row(title: "Mic gain", caption: "Set on the \(engine.inputs.first(where: { $0.uid == engine.inputUID })?.name ?? "microphone") itself.") { EmptyView() }
                SliderRow(label: "Gain", value: String(format: "%.1f dB", g.db),
                          binding: Binding(get: { engine.micGain?.db ?? g.db }, set: { engine.setMicGain($0) }), range: g.min...g.max).padding(.bottom, 6)
                RowDivider()
                Row(title: "Lock gain", caption: engine.gainLockDB != nil ? String(format: "Held at %.1f dB.", engine.gainLockDB ?? g.db) : "Puts the gain back if another app moves it.") {
                    Toggle("Lock gain", isOn: Binding(get: { engine.gainLockDB != nil }, set: { engine.setGainLock($0) })).labelsHidden().toggleStyle(.switch)
                }
            }
            RowDivider()
            Row(title: "Use as the Mac's microphone", caption: "Switches back if AirPods take over.") {
                Toggle("Use as the Mac's microphone", isOn: Binding(get: { engine.isSystemMicrophone }, set: { engine.setSystemMicrophone($0) })).labelsHidden().toggleStyle(.switch)
            }
            if let ms = engine.lastWakeMs {
                RowDivider()
                Row(title: "Last wake-up", caption: "How long the mic took to open.") {
                    Text(String(format: "%.0f ms", ms)).font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(Double(level), 1e-5))
            let frac = min(max((db + 60) / 60, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(db > -3 ? Color.red : db > -12 ? Color.yellow : Color.green).frame(width: g.size.width * frac)
            }
        }
        .accessibilityLabel("Input level")
    }
}

/// The level right now on a −60 to 0 dB scale, with a tick where a threshold sits.
struct ThresholdMeter: View {
    let level: Float
    let thresholdDB: Double
    let note: String
    var body: some View {
        HStack(spacing: 12) {
            Text("Level").font(.system(size: 14)).frame(width: 80, alignment: .leading)
            GeometryReader { g in
                let frac = min(max((DynamicsView.db(level) + 60) / 60, 0), 1)
                let mark = min(max((thresholdDB + 60) / 60, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(DynamicsView.db(level) >= thresholdDB ? Color.accentColor : Color.primary.opacity(0.35)).frame(width: g.size.width * frac)
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary).frame(width: 2, height: 14).offset(x: g.size.width * mark - 1)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Text(note).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .accessibilityElement(children: .ignore).accessibilityLabel("Level against the threshold").accessibilityValue(note)
    }
}

struct DynamicsView: View {
    @EnvironmentObject var engine: Engine

    static func db(_ level: Float) -> Double { 20 * log10(max(Double(level), 1e-5)) }

    struct CompPreset {
        let name: String
        let threshold, ratio, attack, release, makeup: Double
        func apply(_ d: inout Dynamics) {
            d.compThresholdDB = threshold; d.compRatio = ratio; d.compAttackMs = attack; d.compReleaseMs = release; d.compMakeupDB = makeup
        }
    }
    static let compPresets = [
        CompPreset(name: "Gentle", threshold: -20, ratio: 2, attack: 10, release: 200, makeup: 2),
        CompPreset(name: "Voice", threshold: -18, ratio: 3, attack: 8, release: 150, makeup: 3),
        CompPreset(name: "Tight", threshold: -24, ratio: 4, attack: 5, release: 120, makeup: 5),
    ]

    @AppStorage("dynamicsOpen") private var openList = ""

    private func isOpen(_ id: String) -> Bool { openList.split(separator: ",").contains(Substring(id)) }
    private func toggleOpen(_ id: String) {
        var open = Set(openList.split(separator: ",").map(String.init))
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
        openList = open.sorted().joined(separator: ",")
    }

    /// A processor's row: the chevron shows its settings, the switch turns it on. Either works without the other.
    /// `live` says what it is doing right now; what it does in general is in the tooltip.
    private func header(_ id: String, _ title: String, about: String, live: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Button { withAnimation(.easeOut(duration: 0.18)) { toggleOpen(id) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen(id) ? 90 : 0)).frame(width: 12)
                    Text(title).font(.system(size: 15))
                    Spacer(minLength: 8)
                    if let live { Text(live).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(about)
            .accessibilityLabel(isOpen(id) ? "Hide \(title) settings" : "Show \(title) settings")
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    var body: some View {
        Card {
            CardHeader(title: "Dynamics", caption: engine.original ? "Off while Hear Without Processing is on." : nil)
            RowDivider()
            header("gate", "Noise gate", about: "Turns the mic down between phrases.", isOn: $engine.dynamics.gateOn)
            if isOpen("gate") {
                Live(engine.meters) { m in
                ThresholdMeter(level: engine.running ? m.level : 0, thresholdDB: engine.dynamics.gateThresholdDB,
                               note: !engine.dynamics.gateOn ? "Off" : engine.running ? (Self.db(m.level) >= engine.dynamics.gateThresholdDB ? "Open" : "Closed") : "Mic closed")
                }
                SliderRow(label: "Opens at", value: String(format: "%.0f dB", engine.dynamics.gateThresholdDB), binding: $engine.dynamics.gateThresholdDB, range: -80 ... -20)
                SliderRow(label: "Cut by", value: String(format: "%.0f dB", -engine.dynamics.gateRangeDB),
                          binding: Binding(get: { -engine.dynamics.gateRangeDB }, set: { engine.dynamics.gateRangeDB = -$0 }), range: 6...60)
                SliderRow(label: "Hold", value: String(format: "%.0f ms", engine.dynamics.gateHoldMs), binding: $engine.dynamics.gateHoldMs, range: 0...500)
                SliderRow(label: "Release", value: String(format: "%.0f ms", engine.dynamics.gateReleaseMs), binding: $engine.dynamics.gateReleaseMs, range: 20...800).padding(.bottom, 6)
            }
            RowDivider()
            Live(engine.meters) { m in
                header("comp", "Compressor", about: "Evens out loud and quiet speech.",
                       live: engine.dynamics.compOn && engine.running ? String(format: "−%.1f dB", m.reductionDB) : nil, isOn: $engine.dynamics.compOn)
            }
            if isOpen("comp") {
                Live(engine.meters) { m in
                ThresholdMeter(level: engine.running ? m.level : 0, thresholdDB: engine.dynamics.compThresholdDB,
                               note: !engine.dynamics.compOn ? "Off" : engine.running ? String(format: "−%.1f dB", m.reductionDB) : "Mic closed")
                }
                HStack(spacing: 8) {
                    Text("Start from").font(.system(size: 14)).foregroundStyle(.secondary)
                    ForEach(Self.compPresets, id: \.name) { p in
                        Button(p.name) { p.apply(&engine.dynamics) }.buttonStyle(PillButtonStyle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                SliderRow(label: "Starts at", value: String(format: "%.0f dB", engine.dynamics.compThresholdDB), binding: $engine.dynamics.compThresholdDB, range: -50...0)
                SliderRow(label: "Ratio", value: String(format: "%.1f : 1", engine.dynamics.compRatio), binding: $engine.dynamics.compRatio, range: 1...10)
                SliderRow(label: "Attack", value: String(format: "%.0f ms", engine.dynamics.compAttackMs), binding: $engine.dynamics.compAttackMs, range: 0.5...50)
                SliderRow(label: "Release", value: String(format: "%.0f ms", engine.dynamics.compReleaseMs), binding: $engine.dynamics.compReleaseMs, range: 20...600)
                SliderRow(label: "Makeup", value: String(format: "%+.1f dB", engine.dynamics.compMakeupDB), binding: $engine.dynamics.compMakeupDB, range: 0...18).padding(.bottom, 6)
            }
            RowDivider()
            Live(engine.meters) { m in
                header("deess", "De-esser", about: "Softens sharp S sounds.",
                       live: engine.dynamics.deessOn && engine.running && m.deessDB > 0.1 ? String(format: "−%.1f dB", m.deessDB) : nil, isOn: $engine.dynamics.deessOn)
            }
            if isOpen("deess") {
                SliderRow(label: "Amount", value: String(format: "Up to %.0f dB", engine.dynamics.deessAmountDB), binding: $engine.dynamics.deessAmountDB, range: 2...12)
                SliderRow(label: "Frequency", value: String(format: "%.1f kHz", engine.dynamics.deessFreq / 1000), binding: $engine.dynamics.deessFreq, range: 3000...10000).padding(.bottom, 6)
            }
            RowDivider()
            Live(engine.meters) { m in
                header("limiter", "Limiter", about: "Catches loud peaks before they clip.",
                       live: engine.dynamics.limiterOn && engine.running && m.limiterDB > 0.1 ? String(format: "−%.1f dB", m.limiterDB) : nil, isOn: $engine.dynamics.limiterOn)
            }
            if isOpen("limiter") {
                SliderRow(label: "Ceiling", value: String(format: "%.1f dB", engine.dynamics.limiterCeilingDB), binding: $engine.dynamics.limiterCeilingDB, range: -12...0).padding(.bottom, 6)
            }
        }
        .opacity(engine.original ? 0.6 : 1)
    }
}

/// Draws the panel and the editor to PNG files without showing them, in light and dark.
/// Used to check the design without taking over the screen: NoOrangeDot --render <directory>
@MainActor
enum Render {
    /// `sample` is an optional recording of speech, used to draw the live spectrum and an automatic EQ result.
    static func run(directory: String, sample: String? = nil) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Engine.renderOnly = true
        let engine = Engine()
        engine.refreshRecordings()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        if let sample, let audio = AutoEQ.read(URL(fileURLWithPath: sample)), let m = AutoEQ.measure(audio.samples, sampleRate: audio.sampleRate) {
            engine.autoResult = AutoEQ.fit(levels: m.levels, seconds: m.seconds, target: .warm, strength: 1, sampleRate: audio.sampleRate)
            let fft = Spectrum(size: 4096)
            var power = [Float](repeating: 0, count: 2048)
            let start = min(audio.samples.count - 4096, Int(audio.sampleRate) * 4)
            audio.samples.withUnsafeBufferPointer { fft.power($0.baseAddress! + start, into: &power) }
            let levels = Spectrum.bands(power: power, sampleRate: audio.sampleRate, centres: Engine.displayCentres, fraction: 12).map(Float.init)
            engine.scope.spectrumRaw = levels
            engine.scope.spectrumPost = levels.enumerated().map { $1 + Float(engine.responseDB(at: Engine.displayCentres[$0])) }
        }
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let views: [(String, AnyView)] = [
                ("panel", AnyView(MenuPanelContent(model: PanelModel()).environmentObject(engine))),
                ("editor-sound", AnyView(EditorView(tab: .sound).environmentObject(engine))),
                ("editor-recordings", AnyView(EditorView(tab: .recordings).environmentObject(engine))),
                ("editor-playing", AnyView(EditorView(tab: .recordings).environmentObject(engine).onAppear { engine.cueSeconds = (engine.recordings.first?.seconds ?? 0) * 0.4; engine.selection = (engine.recordings.first?.seconds).map { $0 * 0.2...$0 * 0.6 } })),
                ("editor-settings", AnyView(EditorView(tab: .settings).environmentObject(engine))),
                ("mute-button", AnyView(MuteButtonSheet())),
            ]
            for (name, view) in views {
                if name != "editor-playing" { engine.cueSeconds = 0; engine.selection = nil }
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                let size = !name.hasPrefix("editor") ? host.fittingSize : NSSize(width: Double(ProcessInfo.processInfo.environment["NOD_RENDER_WIDTH"] ?? "") ?? 980, height: Double(ProcessInfo.processInfo.environment["NOD_RENDER_HEIGHT"] ?? "") ?? 700)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
                let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
        }
        // The whole window, title bar and toolbar included, built the way the app builds it.
        for dark in [false, true] {
            for (name, tab) in [("window-sound", EditorTab.sound), ("window-recordings", EditorTab.recordings)] {
                engine.cueSeconds = 0; engine.selection = nil
                let host = NSHostingController(rootView: EditorView(tab: tab).environmentObject(engine))
                host.sceneBridgingOptions = [.toolbars, .title]
                let w = NSWindow(contentViewController: host)
                w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                w.toolbarStyle = .unified
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                w.setContentSize(NSSize(width: Double(ProcessInfo.processInfo.environment["NOD_RENDER_WIDTH"] ?? "") ?? 980,
                                        height: Double(ProcessInfo.processInfo.environment["NOD_RENDER_HEIGHT"] ?? "") ?? 700))
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                guard let frame = w.contentView?.superview else { continue }
                frame.layoutSubtreeIfNeeded()
                guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                    try? png.write(to: url)
                    print(url.path)
                }
                w.close()
            }
        }
        let cell: CGFloat = 96, states = AppMark.State.allCases, styles = AppMark.Style.allCases
        let sheet = NSImage(size: NSSize(width: 150 + cell * CGFloat(states.count) + 260, height: 40 + cell * CGFloat(styles.count)), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black]
            for (j, st) in states.enumerated() { (st.rawValue as NSString).draw(at: NSPoint(x: 150 + cell * CGFloat(j) + 24, y: 10), withAttributes: attrs) }
            ("actual size, light and dark" as NSString).draw(at: NSPoint(x: 150 + cell * CGFloat(states.count) + 20, y: 10), withAttributes: attrs)
            for (i, style) in styles.enumerated() {
                let y = 40 + cell * CGFloat(i)
                (style.rawValue as NSString).draw(at: NSPoint(x: 20, y: y + cell / 2 - 8), withAttributes: attrs)
                let barX = 150 + cell * CGFloat(states.count) + 20
                NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: barX, y: y + 20, width: 110, height: 24).fill()
                NSColor(white: 0.13, alpha: 1).setFill(); NSRect(x: barX + 120, y: y + 20, width: 110, height: 24).fill()
                for (j, st) in states.enumerated() {
                    let big = AppMark.image(style, st, scale: 4)
                    big.draw(in: NSRect(x: 150 + cell * CGFloat(j) + (cell - big.size.width) / 2, y: y + (cell - big.size.height) / 2, width: big.size.width, height: big.size.height))
                    let small = AppMark.image(style, st)
                    let r = NSRect(x: barX + 8 + CGFloat(j) * 25, y: y + 32 - small.size.height / 2, width: small.size.width, height: small.size.height)
                    small.draw(in: r)
                    let inv = NSImage(size: small.size, flipped: false) { b in small.draw(in: b); NSColor.white.set(); b.fill(using: .sourceIn); return true }
                    inv.draw(in: r.offsetBy(dx: 120, dy: 0))
                }
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = dir.appendingPathComponent("icons.png"); try? png.write(to: url); print(url.path)
        }
        engine.shutdown()
        return 0
    }
}

/// Lets the user choose the name apps show for the virtual mic.
struct MicNameRow: View {
    @EnvironmentObject var engine: Engine
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        Row(title: "Name apps see", caption: engine.canRenameMic ? nil : "Renaming needs the newer driver. Run the installer once more.") {
            HStack(spacing: 8) {
                TextField(Brand.micName, text: $draft).textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.horizontal, 10).frame(width: 220, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                    .onSubmit { engine.micName = draft }
                    .focused($editing)
                    .accessibilityLabel("Name apps see")
                Button("Rename") { engine.micName = draft }.buttonStyle(PillButtonStyle()).fixedSize()
                    .disabled(draft.trimmingCharacters(in: .whitespaces) == engine.micDisplayName || (draft.isEmpty && engine.micName.isEmpty))
            }
            .disabled(!engine.canRenameMic)
        }
        .onAppear { draft = engine.micName.isEmpty ? engine.micDisplayName : engine.micName; takeFocus() }
        .onReceive(NotificationCenter.default.publisher(for: .focusMicName)) { _ in takeFocus() }
    }

    private func takeFocus() {
        guard EditorRequest.focusMicName else { return }
        EditorRequest.focusMicName = false
        // A field that has only now appeared cannot take the keyboard until the next pass.
        DispatchQueue.main.async { editing = true }
    }
}
