import AppKit
import SwiftUI

enum PanelAction: CaseIterable { case mute, record, equalizer, system, editor, quit }

@MainActor
final class PanelModel: ObservableObject {
    @Published var selected: PanelAction?
    var choose: (PanelAction) -> Void = { _ in }

    func move(_ delta: Int) {
        let all = PanelAction.allCases
        if let selected, let i = all.firstIndex(of: selected) { self.selected = all[(i + delta + all.count) % all.count] }
        else { selected = delta > 0 ? all.first : all.last }
    }
}

/// The response curve as a small drawing, for places where it is shown but not edited.
struct CurveView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            var curve = Path()
            let steps = Int(w / 2)
            for i in 0...steps {
                let f = 20 * pow(1000, Double(i) / Double(steps))
                let db = min(max(engine.responseDB(at: f), -12), 12)
                let pt = CGPoint(x: CGFloat(i) / CGFloat(steps) * w, y: h / 2 - CGFloat(db / 12) * (h / 2 - 2))
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
            }
            ctx.stroke(curve, with: .color(.primary.opacity(engine.bypass ? 0.25 : 0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Equalizer curve")
    }
}

struct MenuPanelContent: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    HeaderLogo(appIcon: engine.appIcon, size: 22)
                    Text(Brand.short).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    if engine.running { Live(engine.meters) { m in LevelMeter(level: m.level) }.frame(width: 64, height: 4) }
                }
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)

            VStack(spacing: 2) {
                row(.mute, title: engine.muted ? "Unmute" : "Mute", symbol: engine.muted ? "mic.slash.fill" : "mic.slash",
                    state: engine.muted ? "Muted" : "", tint: .orange, shortcut: "M")
                row(.record, title: engine.recording ? "Stop Recording" : "Record", symbol: engine.recording ? "stop.circle.fill" : "record.circle",
                    state: engine.recording ? "Recording" : "", tint: .red, shortcut: "R")
                row(.equalizer, title: "Equalizer", symbol: "slider.vertical.3", state: engine.bypass ? "Off" : "On", tint: nil, shortcut: "E")
                row(.system, title: "Use as System Microphone", symbol: engine.isSystemMicrophone ? "checkmark.circle.fill" : "circle",
                    state: engine.isSystemMicrophone ? "On" : "", tint: nil, shortcut: "S")
            }
            .disabled(!engine.driverInstalled)

            HStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                ArtworkView(art: .pixelRule, tint: .primary.opacity(0.67))
            }
            .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sound").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                CurveView().frame(height: 38)
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider().padding(.horizontal, 10)
            VStack(spacing: 2) {
                row(.editor, title: "Open Editor…", symbol: "waveform", state: "", tint: nil, shortcut: "⌘,")
                row(.quit, title: "Quit \(Brand.short)", symbol: "power", state: "", tint: nil, shortcut: "⌘Q")
            }
        }
        .padding(10)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
    }

    private var status: String {
        if let p = engine.configProblem ?? engine.error { return p }
        return engine.statusDetail.isEmpty ? engine.statusTitle : "\(engine.statusTitle)  ·  \(engine.statusDetail)"
    }

    private var summary: String {
        let d = engine.dynamics
        let extras = [d.gateOn ? "Gate" : nil, d.compOn ? "Compressor" : nil, d.deessOn ? "De-esser" : nil].compactMap { $0 }
        let mic = engine.inputs.first(where: { $0.uid == engine.inputUID })?.name ?? "No microphone"
        return extras.isEmpty ? mic : "\(mic)  ·  \(extras.joined(separator: " + "))"
    }

    private func row(_ action: PanelAction, title: String, symbol: String, state: String, tint: Color?, shortcut: String) -> some View {
        let active = tint != nil && !state.isEmpty
        return Button { model.choose(action) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(active ? AnyShapeStyle(tint!) : AnyShapeStyle(.secondary)).frame(width: 22)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if !state.isEmpty { Text(state).font(.system(size: 12)).foregroundStyle(active ? AnyShapeStyle(tint!) : AnyShapeStyle(.secondary)) }
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary).frame(minWidth: 18, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .background {
                if model.selected == action { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.09)) }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.selected = action } else if model.selected == action { model.selected = nil }
        }
        .accessibilityLabel(state.isEmpty ? title : "\(title), \(state)")
        .accessibilityAddTraits(model.selected == action ? .isSelected : [])
    }
}

private extension NSImage {
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class PanelWindow: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// The panel under the menu bar icon: a borderless glass surface, sized to its content each time it opens.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let panel = PanelWindow()
    private let engine: Engine
    private let onAction: (PanelAction) -> Void
    private let model = PanelModel()
    private weak var button: NSStatusBarButton?
    private var outsideClick: Any?
    private(set) var isOpen = false

    init(engine: Engine, onAction: @escaping (PanelAction) -> Void) {
        self.engine = engine
        self.onAction = onAction
        super.init()
        panel.delegate = self
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        model.choose = { [weak self] in self?.choose($0) }
    }

    private func surface() -> NSView {
        let hosting = NSHostingView(rootView: MenuPanelContent(model: model).environmentObject(engine))
        let size = hosting.fittingSize
        let bounds = NSRect(origin: .zero, size: size)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        let surface = NSVisualEffectView(frame: bounds)
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.maskImage = .roundedMask(radius: 16)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = hosting
            glass.autoresizingMask = [.width, .height]
            surface.addSubview(glass)
        } else {
            surface.addSubview(hosting)
        }
        return surface
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isOpen { close(); return }
        guard let window = button.window else { return }
        self.button = button
        model.selected = nil
        let content = surface()
        let size = content.frame.size
        panel.contentView = content
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor
        let x = min(max(anchor.maxX - size.width + 12, screen.minX + 8), screen.maxX - size.width - 8)
        let y = max(screen.minY + 8, anchor.minY - size.height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        isOpen = true
        button.highlight(true)
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
        panel.orderOut(nil)
        button?.highlight(false)
        panel.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// Mute, Record and Equalizer keep the panel open so the new state is visible; the rest close it.
    private func choose(_ action: PanelAction) {
        if action == .editor || action == .quit { close() }
        onAction(action)
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close()                                  // escape
        case 126: model.move(-1)                          // up
        case 125: model.move(1)                           // down
        case 48: model.move(event.modifierFlags.contains(.shift) ? -1 : 1) // tab
        case 36, 76: if let a = model.selected { choose(a) }               // return, keypad enter
        default:
            let ch = event.charactersIgnoringModifiers?.lowercased()
            if event.modifierFlags.contains(.command) {
                switch ch { case ",": choose(.editor); case "q": choose(.quit); default: return false }
            } else {
                switch ch { case "m": choose(.mute); case "r": choose(.record); case "e": choose(.equalizer); case "s": choose(.system); default: return false }
            }
        }
        return true
    }
}
