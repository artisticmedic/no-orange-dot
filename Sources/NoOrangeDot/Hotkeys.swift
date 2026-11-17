import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A system-wide keyboard shortcut, written in config.json as "ctrl+opt+cmd+m".
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon: cmdKey, optionKey, controlKey, shiftKey
    var key: String

    static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "space": kVK_Space,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
    ]

    /// Parses "ctrl+opt+cmd+m". Function keys may stand alone; any other key needs Control or Command,
    /// because Option and Shift alone type characters.
    init?(_ text: String) {
        var mods: UInt32 = 0, name: String?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: if name != nil { return nil }; name = part
            }
        }
        guard let name, let code = Self.keys[name] else { return nil }
        guard Self.isFunctionKey(name) || mods & UInt32(cmdKey | controlKey) != 0 else { return nil }
        keyCode = UInt32(code); modifiers = mods; key = name
    }

    init?(event: NSEvent) {
        guard let name = Self.keys.first(where: { $0.value == Int(event.keyCode) })?.key else { return nil }
        let f = event.modifierFlags
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        self.init((parts + [name]).joined(separator: "+"))
    }

    var text: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("opt") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// "⌃⌥⌘M"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Self.symbols[key] ?? key.uppercased())
    }

    private static let symbols = ["space": "Space", "up": "↑", "down": "↓", "left": "←", "right": "→"]
    private static func isFunctionKey(_ name: String) -> Bool { name.hasPrefix("f") && name.count > 1 }

    var menuKey: String {
        switch key {
        case "space": return " "
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "left": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case _ where Self.isFunctionKey(key): return String(UnicodeScalar(NSF1FunctionKey + (Int(key.dropFirst()) ?? 1) - 1)!)
        default: return key
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }
}

@MainActor
protocol HotkeyRegistrar: AnyObject {
    func register(_ id: UInt32, shortcut: Shortcut) -> Bool
    func unregister(_ id: UInt32)
}

@MainActor
private final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    func unregister(_ id: UInt32) {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
    }

    func register(_ id: UInt32, shortcut: Shortcut) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.invoke(id) } }
                return noErr
            }, 1, &spec, nil, nil)
            guard result == noErr else { return false }
            installed = true
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4E4F4421, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }
}

/// Registers shortcuts that work in any app. Needs no permission from the user.
@MainActor
final class Hotkeys {
    struct Binding {
        let id: UInt32
        let shortcut: Shortcut?
        let action: () -> Void
    }

    static let shared = Hotkeys(registrar: CarbonHotkeyRegistrar())
    var registrationFailed: ([UInt32]) -> Void = { _ in }
    private let registrar: HotkeyRegistrar
    private var bindings: [Binding] = []
    private var registered: Set<UInt32> = []
    private var suspended = false

    init(registrar: HotkeyRegistrar) { self.registrar = registrar }

    func replace(with bindings: [Binding]) {
        unregisterAll()
        self.bindings = bindings
        if !suspended { registerAll() }
    }

    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        registerAll()
    }

    func invoke(_ id: UInt32) {
        guard !suspended, registered.contains(id) else { return }
        bindings.first { $0.id == id }?.action()
    }

    private func unregisterAll() {
        for id in registered.sorted() { registrar.unregister(id) }
        registered.removeAll()
    }

    private func registerAll() {
        var refused: [UInt32] = []
        for binding in bindings {
            guard let shortcut = binding.shortcut else { continue }
            if registrar.register(binding.id, shortcut: shortcut) { registered.insert(binding.id) }
            else { refused.append(binding.id) }
        }
        if !refused.isEmpty { registrationFailed(refused) }
    }
}

@MainActor
final class ShortcutCapture: ObservableObject {
    static let shared = ShortcutCapture(hotkeys: .shared)
    @Published private(set) var owner: UUID?
    private let hotkeys: Hotkeys
    private let installMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void
    private let invalidInput: () -> Void
    private var monitor: Any?
    private var accept: ((String) -> Void)?

    init(hotkeys: Hotkeys,
         installMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) },
         removeMonitor: @escaping (Any) -> Void = NSEvent.removeMonitor,
         invalidInput: @escaping () -> Void = NSSound.beep) {
        self.hotkeys = hotkeys
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
        self.invalidInput = invalidInput
    }

    func start(owner: UUID, accept: @escaping (String) -> Void) {
        if self.owner == nil {
            hotkeys.suspend()
            monitor = installMonitor { [weak self] event in
                guard let self, self.handle(keyCode: event.keyCode, shortcut: Shortcut(event: event)) else { return event }
                return nil
            }
            guard monitor != nil else { hotkeys.resume(); invalidInput(); return }
        }
        self.owner = owner
        self.accept = accept
    }

    func cancel(owner: UUID) {
        guard self.owner == owner else { return }
        stop()
    }

    @discardableResult
    func handle(keyCode: UInt16, shortcut: Shortcut?) -> Bool {
        guard owner != nil else { return false }
        if keyCode == UInt16(kVK_Escape) { stop(); return true }
        let value: String
        if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete) { value = "" }
        else if let shortcut { value = shortcut.text }
        else { invalidInput(); return true }
        let receive = accept
        stop()
        receive?(value)
        return true
    }

    private func stop() {
        if let monitor { removeMonitor(monitor) }
        monitor = nil
        owner = nil
        accept = nil
        hotkeys.resume()
    }
}

/// A button that shows a shortcut and records a new one: click, press the keys. Escape cancels, Delete clears.
@MainActor
struct ShortcutButton: View {
    @Binding var text: String
    @State private var owner = UUID()
    @ObservedObject private var capture = ShortcutCapture.shared
    private var recording: Bool { capture.owner == owner }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if recording { capture.cancel(owner: owner) }
                else { capture.start(owner: owner) { text = $0 } }
            } label: {
                Text(recording ? "Press the keys…" : Shortcut(text)?.display ?? "Set Shortcut")
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).frame(minWidth: 96)
            }
            .buttonStyle(PillButtonStyle(prominent: recording))
            .help("Click, then press the keys. Escape cancels.")
            if Shortcut(text) != nil, !recording {
                IconButton(symbol: "xmark.circle.fill", label: "Remove this shortcut", tint: .secondary) { text = "" }
            }
        }
        .onDisappear { capture.cancel(owner: owner) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            capture.cancel(owner: owner)
        }
    }
}
