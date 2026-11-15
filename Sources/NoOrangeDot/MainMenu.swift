import AppKit
import SwiftUI

extension Notification.Name {
    /// Sent with a tab's name to show that page of the window.
    static let showTab = Notification.Name("NoOrangeDot.showTab")
}

/// A menu item that runs a closure and reads its tick, title and availability each time its menu opens.
final class ActionItem: NSMenuItem, NSMenuItemValidation {
    private var run: () -> Void = {}
    private var isOn: (() -> Bool)?
    private var liveTitle: (() -> String)?
    private var available: (() -> Bool)?

    convenience init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command,
                     on: (() -> Bool)? = nil, title liveTitle: (() -> String)? = nil, when available: (() -> Bool)? = nil,
                     run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        self.run = run; self.isOn = on; self.liveTitle = liveTitle; self.available = available
    }

    @objc private func fire() { run() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let isOn { state = isOn() ? .on : .off }
        if let liveTitle { title = liveTitle() }
        return available?() ?? true
    }
}

/// The menus at the top of the screen. Every setting and action in the window is also here, so the
/// whole app can be driven from the keyboard.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    private let engine: Engine
    private let openEditor: () -> Void
    private let inputs = NSMenu(title: "Input"), presets = NSMenu(title: "Presets")

    init(engine: Engine, openEditor: @escaping () -> Void) {
        self.engine = engine; self.openEditor = openEditor
        super.init()
    }

    private func show(_ tab: EditorTab) {
        openEditor()
        // A window that is only now being made is not listening yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotificationCenter.default.post(name: .showTab, object: tab.rawValue) }
    }

    func install() {
        let e = engine, main = NSMenu()
        @discardableResult func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(), menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func sub(_ title: String, _ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }
        let driver = { e.driverInstalled }

        add(Brand.short, [
            NSMenuItem(title: "About \(Brand.short)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            ActionItem("Check for Updates…") { [weak self] in self?.show(.settings); Updater.shared.check() },
            .separator(),
            ActionItem("Settings…", key: ",") { [weak self] in self?.show(.settings) },
            .separator(),
            ActionItem("Open at Login", on: { e.launchAtLogin }) { e.setLaunchAtLogin(!e.launchAtLogin) },
            ActionItem("Show in Dock", on: { e.showInDock }) { e.showInDock.toggle() },
            ActionItem("Update Automatically", on: { e.autoUpdate }) { e.autoUpdate.toggle() },
            .separator(),
            NSMenuItem(title: "Hide \(Brand.short)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            { let i = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); i.keyEquivalentModifierMask = [.command, .option]; return i }(),
            NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit \(Brand.short)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])

        add("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])

        add("View", [
            ActionItem("Sound", key: "1", mods: [.command, .option]) { [weak self] in self?.show(.sound) },
            ActionItem("Recordings", key: "2", mods: [.command, .option]) { [weak self] in self?.show(.recordings) },
            ActionItem("Settings", key: "3", mods: [.command, .option]) { [weak self] in self?.show(.settings) },
            .separator(),
            ActionItem("See Your Voice", key: "v", mods: [.command, .shift], on: { e.monitoring }, when: driver) { [weak self] in
                if !e.monitoring { self?.show(.sound) }
                e.monitoring.toggle()
            },
        ])

        inputs.delegate = self
        add("Microphone", [
            ActionItem("Mute", key: "m", mods: [.command, .shift], title: { e.muted ? "Unmute" : "Mute" }, when: driver) { e.muted.toggle() },
            ActionItem("Listen to Yourself", key: "l", mods: [.command, .shift], on: { e.listenBack }, when: driver) { e.listenBack.toggle() },
            .separator(),
            sub("Input", inputs),
            ActionItem("Use as the Mac's Microphone", on: { e.isSystemMicrophone }, when: driver) { e.setSystemMicrophone(!e.isSystemMicrophone) },
            .separator(),
            ActionItem("Raise Mic Gain", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.command, .option], when: { e.micGain != nil }) {
                if let g = e.micGain { e.setMicGain(g.db + 1) }
            },
            ActionItem("Lower Mic Gain", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: [.command, .option], when: { e.micGain != nil }) {
                if let g = e.micGain { e.setMicGain(g.db - 1) }
            },
            ActionItem("Lock Gain", on: { e.gainLockDB != nil }, when: { e.micGain != nil }) { e.setGainLock(e.gainLockDB == nil) },
            .separator(),
            ActionItem("Rename the Mic…") { [weak self] in self?.show(.settings) },
        ])

        presets.delegate = self
        let compressor = NSMenu(title: "Compressor Setting")
        for p in DynamicsView.compPresets { compressor.addItem(ActionItem(p.name) { p.apply(&e.dynamics) }) }
        add("Sound", [
            ActionItem("Equalizer", key: "e", on: { !e.bypass }) { e.bypass.toggle() },
            ActionItem("Add Band", key: "b", mods: [.command, .shift]) { [weak self] in
                self?.show(.sound)
                e.bands.append(Band(type: .bell, freq: 1000, gainDB: 0, q: 1))
            },
            .separator(),
            ActionItem("Noise Gate", key: "g", mods: [.command, .shift], on: { e.dynamics.gateOn }) { e.dynamics.gateOn.toggle() },
            ActionItem("Compressor", key: "c", mods: [.command, .shift], on: { e.dynamics.compOn }) { e.dynamics.compOn.toggle() },
            sub("Compressor Setting", compressor),
            ActionItem("Limiter", key: "k", mods: [.command, .shift], on: { e.dynamics.limiterOn }) { e.dynamics.limiterOn.toggle() },
            .separator(),
            ActionItem("Raise Output Level", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.command, .control]) { e.outputGainDB = min(e.outputGainDB + 1, 12) },
            ActionItem("Lower Output Level", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: [.command, .control]) { e.outputGainDB = max(e.outputGainDB - 1, -12) },
            .separator(),
            sub("Presets", presets),
            ActionItem("Save Current as Preset…", key: "s") { [weak self] in self?.savePreset() },
        ])

        add("Recordings", [
            ActionItem("Start Recording", key: "r", title: { e.recording ? "Stop Recording" : "Start Recording" }, when: driver) { e.toggleRecording() },
            .separator(),
            ActionItem("Play Last Recording", key: "p", when: { !e.recordings.isEmpty }) { [weak self] in
                self?.show(.recordings)
                if let r = e.recordings.first { e.startAudition(r) }
            },
            ActionItem("Stop Playing", key: ".", when: { e.auditioning != nil }) { e.stopAudition() },
            .separator(),
            ActionItem("Show Recordings") { [weak self] in self?.show(.recordings) },
            ActionItem("Open Recordings Folder", key: "o", mods: [.command, .shift]) { NSWorkspace.shared.open(e.recordingsURL) },
        ])

        NSApp.windowsMenu = add("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            .separator(),
            ActionItem("\(Brand.short) Window", key: "0") { [weak self] in self?.openEditor() },
            NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""),
        ])

        NSApp.helpMenu = add("Help", [
            ActionItem("\(Brand.short) on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/artisticmedic/no-orange-dot")!) },
            ActionItem("Report a Problem…") { NSWorkspace.shared.open(URL(string: CrashReport.issues)!) },
        ])
        NSApp.mainMenu = main
    }

    /// The lists of microphones and presets change, so they are filled in when their menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let e = engine
        menu.removeAllItems()
        if menu === inputs {
            for input in e.inputs {
                menu.addItem(ActionItem(input.name, on: { e.inputUID == input.uid }) { e.inputUID = input.uid })
            }
            if e.inputs.isEmpty { menu.addItem(ActionItem("No microphone found", when: { false }) {}) }
        } else if menu === presets {
            let current = e.currentPreset?.id
            for (i, preset) in e.presets.enumerated() {
                menu.addItem(ActionItem(preset.name, key: i < 9 ? "\(i + 1)" : "", on: { preset.id == current }) { e.use(preset) })
            }
            if e.presets.isEmpty { menu.addItem(ActionItem("No presets saved", when: { false }) {}) }
        }
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save the current sound as a preset"
        alert.informativeText = "A preset saves the EQ, gate, compressor, limiter and output level."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { engine.savePreset(named: name) }
    }
}
