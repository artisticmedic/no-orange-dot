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

    /// Parses "ctrl+opt+cmd+m". Function keys may stand alone; any other key needs Control, Option or Command.
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
        guard Self.isFunctionKey(name) || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
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

    /// The same shortcut as a menu item shows it.
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

/// Registers shortcuts that work in any app. Needs no permission from the user.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Returns false when macOS refuses the combination, usually because something else holds it.
    @discardableResult
    func set(_ id: UInt32, _ shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        actions[id] = action
        guard let shortcut else { return true }
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.actions[id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4E4F4421, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }
}

/// A button that shows a shortcut and records a new one: click, press the keys. Escape cancels, Delete clears.
struct ShortcutButton: View {
    @Binding var text: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press the keys…" : Shortcut(text)?.display ?? "Set Shortcut")
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).frame(minWidth: 96)
            }
            .buttonStyle(PillButtonStyle(prominent: recording))
            .help("Click, then press the keys. Escape cancels.")
            if Shortcut(text) != nil, !recording {
                IconButton(symbol: "xmark.circle.fill", label: "Remove this shortcut", tint: .secondary) { text = "" }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) { text = ""; stop(); return nil }
            if let s = Shortcut(event: event) { text = s.text; stop() } else { NSSound.beep() }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
