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
            let w = NSWindow(contentViewController: host)
            w.title = Brand.short
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // An empty unified toolbar gives the taller title bar, so the window buttons sit level with our own top bar.
            w.toolbar = NSToolbar()
            w.toolbarStyle = .unified
            w.titlebarSeparatorStyle = .none
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
        var refused: [String] = []
        if !Hotkeys.shared.set(1, Shortcut(engine.muteShortcut), action: { [weak self] in self?.engine.muted.toggle() }) { refused.append(Shortcut(engine.muteShortcut)?.display ?? engine.muteShortcut) }
        if !Hotkeys.shared.set(2, Shortcut(engine.recordShortcut), action: { [weak self] in self?.engine.toggleRecording() }) { refused.append(Shortcut(engine.recordShortcut)?.display ?? engine.recordShortcut) }
        if !refused.isEmpty { engine.error = "macOS wouldn't register \(refused.joined(separator: " or ")). Another app may already use it." }
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
        engine.stopAudition()
        engine.monitoring = false
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
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Surface.card))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Surface.border, lineWidth: 1))
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
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

struct SliderRow: View {
    let label: String
    let value: String
    @Binding var binding: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Slider(value: $binding, in: range)
            Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .accessibilityElement(children: .combine).accessibilityLabel(label).accessibilityValue(value)
    }
}

struct TopBarButtonStyle: ButtonStyle {
    var active: Bool
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? tint : Color.primary)
            .padding(.horizontal, 12).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? tint.opacity(0.16) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? tint.opacity(0.35) : Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The system sidebar material, so the window's left column picks up the desktop behind it.
struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Every other button with words on it. `prominent` inverts it: label colour fill, background-colour text.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.horizontal, 13).frame(minHeight: 30)
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
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
                .frame(width: 34, height: 34)
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

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                ScrollView {
                    page.padding(.horizontal, 28).padding(.vertical, 24)
                        .frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
            .background(Surface.page)
        }
        .frame(minWidth: 860, minHeight: 560)
        .ignoresSafeArea()
        .onAppear { takeRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .showTab)) { _ in takeRequest() }
    }

    private func takeRequest() {
        if let wanted = EditorRequest.tab { tab = wanted; EditorRequest.tab = nil }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 9) {
                HeaderLogo(appIcon: engine.appIcon, size: 30)
                Text(Brand.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
            if engine.driverInstalled {
                MuteButton(muted: engine.muted) { engine.muted.toggle() }.padding(.horizontal, 4).padding(.bottom, 12)
            }
            ForEach(EditorTab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                            .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        Text(t.rawValue).font(.system(size: 14, weight: tab == t ? .medium : .regular))
                        Spacer()
                        if t == .recordings, !engine.recordings.isEmpty {
                            Text("\(engine.recordings.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(tab == t ? 0.10 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
            Spacer()
            status
        }
        .padding(.horizontal, 10).padding(.top, 62).padding(.bottom, 12)
        .background(SidebarBackground())
    }

    /// What the mic is doing right now. Always on screen, whichever page is open.
    private var status: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                slot.accessibilityHidden(true)
                Text(engine.statusTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail)
                    .help(engine.statusDetail.isEmpty ? engine.statusTitle : "\(engine.statusTitle). \(engine.statusDetail).")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 12)
            Live(engine.meters) { m in LevelMeter(level: engine.running ? m.level : 0) }.frame(height: 5).opacity(engine.running ? 1 : 0.4)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            micMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// Where the icon of the app using the mic goes. Empty and dashed while no app has it.
    @ViewBuilder private var slot: some View {
        if let icon = engine.listenerIcon, engine.running {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
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
            .frame(width: 30, height: 30)
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
                Text(engine.inputs.first(where: { $0.uid == engine.inputUID })?.name ?? "Choose a microphone").font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Change the microphone").accessibilityLabel("Microphone")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(tab.rawValue).font(.system(size: 15, weight: .semibold))
            Spacer()
            if engine.driverInstalled {
                Button { if engine.error?.hasPrefix("Listen back") == true { engine.error = nil }; engine.listenBack.toggle() } label: { Label(engine.listenBack ? "Listening" : "Listen", systemImage: "headphones") }
                    .buttonStyle(TopBarButtonStyle(active: engine.listenBack, tint: .accentColor))
                    .help("Hear your own voice, with the EQ, in your headphones")
                    .accessibilityLabel(engine.listenBack ? "Stop listening to yourself" : "Listen to yourself")
                Button { engine.toggleRecording() } label: { Label(engine.recording ? "Stop" : "Record", systemImage: engine.recording ? "stop.fill" : "record.circle") }
                    .buttonStyle(TopBarButtonStyle(active: engine.recording, tint: .red))
                    .accessibilityLabel(engine.recording ? "Stop recording" : "Record")
            }
        }
        .padding(.leading, 28).padding(.trailing, 16)
        .frame(height: 52)
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let e = engine.configProblem ?? engine.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
            CrashBanner()
            if !engine.driverInstalled {
                Card { Row(title: "The microphone driver is missing", caption: "Run the installer again. Until it is back, no app can see the microphone.") { EmptyView() } }
            } else {
                AuditionBar()
                switch tab {
                case .sound:
                    VStack(spacing: 8) { SectionLabel(text: "Tone"); EQView(graphHeight: 280) }
                    VStack(spacing: 8) { SectionLabel(text: "Dynamics"); DynamicsView() }
                case .recordings:
                    RecordingsView()
                case .settings:
                    VStack(spacing: 8) { SectionLabel(text: "Microphone priority"); MicOrderCard() }
                    VStack(spacing: 8) { SectionLabel(text: "Microphone"); general }
                    VStack(spacing: 8) { SectionLabel(text: "Shortcuts"); shortcuts }
                    VStack(spacing: 8) { SectionLabel(text: "App"); app }
                    VStack(spacing: 8) { SectionLabel(text: "Updates"); updates }
                    VStack(spacing: 8) { SectionLabel(text: "Automation"); CLIToolView() }
                }
            }
        }
    }

    private var shortcuts: some View { ShortcutsCard() }

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
            Row(title: "App icon", caption: "The icon in the Dock and Command-Tab while the app is running.") {
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
            Row(title: "Show in Dock", caption: "Keeps the app in the Dock when this window is closed.") {
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
            Row(title: "Real microphone", caption: "Choose a microphone for now. Its EQ and dynamics stay saved, and your priority list stays unchanged.") {
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
                Row(title: "Mic gain", caption: "The preamp inside \(engine.inputs.first(where: { $0.uid == engine.inputUID })?.name ?? "the microphone"), set on the hardware itself.") { EmptyView() }
                SliderRow(label: "Gain", value: String(format: "%.1f dB", g.db),
                          binding: Binding(get: { engine.micGain?.db ?? g.db }, set: { engine.setMicGain($0) }), range: g.min...g.max).padding(.bottom, 6)
                RowDivider()
                Row(title: "Lock gain", caption: engine.gainLockDB != nil ? String(format: "Held at %.1f dB. Changes from other apps are undone.", engine.gainLockDB ?? g.db)
                                                                         : "Holds the gain where it is, and puts it back if another app moves it.") {
                    Toggle("Lock gain", isOn: Binding(get: { engine.gainLockDB != nil }, set: { engine.setGainLock($0) })).labelsHidden().toggleStyle(.switch)
                }
            }
            RowDivider()
            Row(title: "Use as the Mac's microphone", caption: "Apps that follow the Mac's sound settings get \(engine.micDisplayName).") {
                Toggle("Use as the Mac's microphone", isOn: Binding(get: { engine.isSystemMicrophone }, set: { engine.setSystemMicrophone($0) })).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            Row(title: "Output level", caption: "Applied after the EQ, gate and compressor.") { EmptyView() }
            SliderRow(label: "Level", value: String(format: "%+.1f dB", engine.outputGainDB), binding: $engine.outputGainDB, range: -12...12).padding(.bottom, 6)
            if let ms = engine.lastWakeMs {
                RowDivider()
                Row(title: "Last wake-up", caption: "How long the mic took to open the last time an app asked.") {
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
            Text("Level").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
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
            Text(note).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
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

    var body: some View {
        Card {
            Row(title: "Noise gate", caption: "Turns the mic down between phrases.") {
                Toggle("Noise gate", isOn: $engine.dynamics.gateOn).labelsHidden().toggleStyle(.switch)
            }
            if engine.dynamics.gateOn {
                Live(engine.meters) { m in
                ThresholdMeter(level: engine.running ? m.level : 0, thresholdDB: engine.dynamics.gateThresholdDB,
                               note: engine.running ? (Self.db(m.level) >= engine.dynamics.gateThresholdDB ? "Open" : "Closed") : "Mic closed")
                }
                SliderRow(label: "Opens at", value: String(format: "%.0f dB", engine.dynamics.gateThresholdDB), binding: $engine.dynamics.gateThresholdDB, range: -80 ... -20)
                SliderRow(label: "Cut by", value: String(format: "%.0f dB", -engine.dynamics.gateRangeDB),
                          binding: Binding(get: { -engine.dynamics.gateRangeDB }, set: { engine.dynamics.gateRangeDB = -$0 }), range: 6...60)
                SliderRow(label: "Hold", value: String(format: "%.0f ms", engine.dynamics.gateHoldMs), binding: $engine.dynamics.gateHoldMs, range: 0...500)
                SliderRow(label: "Release", value: String(format: "%.0f ms", engine.dynamics.gateReleaseMs), binding: $engine.dynamics.gateReleaseMs, range: 20...800).padding(.bottom, 6)
            }
            RowDivider()
            Live(engine.meters) { m in
            Row(title: "Compressor", caption: engine.dynamics.compOn && engine.running
                ? String(format: "Turning the loud parts down %.1f dB.", m.reductionDB) : "Evens out loud and quiet speech.") {
                Toggle("Compressor", isOn: $engine.dynamics.compOn).labelsHidden().toggleStyle(.switch)
            }
            }
            if engine.dynamics.compOn {
                Live(engine.meters) { m in
                ThresholdMeter(level: engine.running ? m.level : 0, thresholdDB: engine.dynamics.compThresholdDB,
                               note: engine.running ? String(format: "−%.1f dB", m.reductionDB) : "Mic closed")
                }
                HStack(spacing: 8) {
                    Text("Start from").font(.system(size: 13)).foregroundStyle(.secondary)
                    ForEach(Self.compPresets, id: \.name) { p in
                        Button(p.name) { p.apply(&engine.dynamics) }.buttonStyle(PillButtonStyle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                SliderRow(label: "Starts at", value: String(format: "%.0f dB", engine.dynamics.compThresholdDB), binding: $engine.dynamics.compThresholdDB, range: -50...0)
                SliderRow(label: "Ratio", value: String(format: "%.1f : 1", engine.dynamics.compRatio), binding: $engine.dynamics.compRatio, range: 1...10)
                SliderRow(label: "Attack", value: String(format: "%.0f ms", engine.dynamics.compAttackMs), binding: $engine.dynamics.compAttackMs, range: 0.5...50)
                SliderRow(label: "Release", value: String(format: "%.0f ms", engine.dynamics.compReleaseMs), binding: $engine.dynamics.compReleaseMs, range: 20...600)
                SliderRow(label: "Makeup", value: String(format: "%+.1f dB", engine.dynamics.compMakeupDB), binding: $engine.dynamics.compMakeupDB, range: 0...18).padding(.bottom, 6)
            }
            RowDivider()
            Live(engine.meters) { m in
            Row(title: "Limiter", caption: engine.dynamics.limiterOn && engine.running && m.limiterDB > 0.1
                ? String(format: "Pulled a peak down %.1f dB.", m.limiterDB) : "Catches loud peaks before they clip.") {
                Toggle("Limiter", isOn: $engine.dynamics.limiterOn).labelsHidden().toggleStyle(.switch)
            }
            }
            if engine.dynamics.limiterOn {
                SliderRow(label: "Ceiling", value: String(format: "%.1f dB", engine.dynamics.limiterCeilingDB), binding: $engine.dynamics.limiterCeilingDB, range: -12...0).padding(.bottom, 6)
            }
        }
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
                ("editor-playing", AnyView(EditorView(tab: .recordings).environmentObject(engine).onAppear { engine.auditioning = engine.recordings.first?.url; engine.meters.auditionProgress = 0.4 })),
                ("editor-settings", AnyView(EditorView(tab: .settings).environmentObject(engine))),
                ("mute-button", AnyView(MuteButtonSheet())),
            ]
            for (name, view) in views {
                if name != "editor-playing" { engine.auditioning = nil }
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                let size = !name.hasPrefix("editor") ? host.fittingSize : NSSize(width: 980, height: Double(ProcessInfo.processInfo.environment["NOD_RENDER_HEIGHT"] ?? "") ?? 700)
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
        Row(title: "Name apps see", caption: engine.canRenameMic ? "What this mic is called in Zoom, Meet, other apps and the Mac's sound settings."
                                                                 : "Renaming needs the newer driver. Run the installer once more.") {
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
