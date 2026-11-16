import AppKit
import SwiftUI

extension Notification.Name {
    /// Sent with a tab's name to show that page of the window.
    static let showTab = Notification.Name("NoOrangeDot.showTab")
    /// Puts the keyboard in the field that renames the mic.
    static let focusMicName = Notification.Name("NoOrangeDot.focusMicName")
    /// The command line tool was installed or removed from the menus.
    static let cliToolChanged = Notification.Name("NoOrangeDot.cliToolChanged")
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

/// The menus at the top of the screen. They carry the app's settings and actions so it can be driven
/// from the keyboard. Only the standard Mac shortcuts are built in (Quit, Hide, Close, Minimize,
/// Settings, and the Edit menu); every other shortcut is one the user set.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    static weak var current: MainMenu?

    private let engine: Engine
    private let openEditor: () -> Void
    private let inputs = NSMenu(title: "Input"), presets = NSMenu(title: "Presets"), replace = NSMenu(title: "Replace Preset"),
                delete = NSMenu(title: "Delete Preset"), curves = NSMenu(title: "Earlier Curves"), play = NSMenu(title: "Play")
    /// Items that can carry a user's shortcut, by command ID.
    private var items: [String: NSMenuItem] = [:]
    private var applied: [String] = ["\u{0}"]

    init(engine: Engine, openEditor: @escaping () -> Void) {
        self.engine = engine; self.openEditor = openEditor
        super.init()
        Self.current = self
    }

    /// The text being typed into, when the keyboard is in a text field.
    private static var editingText: NSText? { NSApp.keyWindow?.firstResponder as? NSText }

    private func show(_ tab: EditorTab, then name: Notification.Name? = nil) {
        openEditor()
        // A window that is only now being made is not listening yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotificationCenter.default.post(name: .showTab, object: tab.rawValue) }
        if let name { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: name, object: nil) } }
    }

    /// A command from the list in Commands.swift, which gives it its name and lets the user set its shortcut.
    private func cmd(_ id: String, _ title: String? = nil, on: (() -> Bool)? = nil, title live: (() -> String)? = nil,
                     when: (() -> Bool)? = nil, run: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title ?? MenuCommand.named(id)?.title ?? id, on: on, title: live, when: when, run: run)
        items[id] = item
        return item
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
        func sub(_ title: String, _ menu: NSMenu, _ items: [NSMenuItem] = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            items.forEach(menu.addItem)
            item.submenu = menu
            return item
        }
        let driver = { e.driverInstalled }
        let band = { e.selectedBandIndex != nil }
        let gainBand = { e.selectedBandIndex.map { e.bands[$0].type.hasGain } ?? false }
        for menu in [inputs, replace, delete, curves, play] { menu.delegate = self }

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        add(Brand.short, [
            NSMenuItem(title: "About \(Brand.short)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            cmd("check-updates") { [weak self] in self?.show(.settings); Updater.shared.check() },
            cmd("install-update", title: { Updater.shared.available.map { "Install Version \($0.version)…" } ?? "Install Update…" },
                when: { Updater.shared.available != nil }) { Updater.shared.install() },
            cmd("auto-check", on: { e.autoUpdate }) { e.autoUpdate.toggle() },
            .separator(),
            ActionItem("Settings…", key: ",") { [weak self] in self?.show(.settings) },
            cmd("open-at-login", on: { e.launchAtLogin }) { e.setLaunchAtLogin(!e.launchAtLogin) },
            cmd("show-in-dock", on: { e.showInDock }) { e.showInDock.toggle() },
            sub("App Icon", NSMenu(title: "App Icon"), [
                ActionItem("Paint", on: { e.appIcon == "paint" }) { e.appIcon = "paint" },
                ActionItem("Carbon", on: { e.appIcon == "carbon" }) { e.appIcon = "carbon" },
            ]),
            sub("Command Line Tool", NSMenu(title: "Command Line Tool"), [
                ActionItem("Install", title: { CLITool.state == .notInstalled ? "Install" : "Replace" }) { Self.cliTool(CLITool.install) },
                ActionItem("Test", when: { CLITool.state != .notInstalled }) { Self.report(CLITool.test().message) },
                ActionItem("Remove", when: { CLITool.state != .notInstalled }) { Self.cliTool(CLITool.remove) },
                .separator(),
                ActionItem("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(CLITool.link, forType: .string) },
            ]),
            .separator(),
            sub("Services", services),
            .separator(),
            NSMenuItem(title: "Hide \(Brand.short)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            { let i = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); i.keyEquivalentModifierMask = [.command, .option]; return i }(),
            NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit \(Brand.short)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])

        add("Edit", [
            // In a text field this undoes typing. Anywhere else it brings back the curve from before the last EQ change.
            ActionItem("Undo", key: "z", title: { Self.editingText != nil ? "Undo" : "Undo EQ Change" },
                       when: { Self.editingText?.undoManager?.canUndo ?? !e.history.isEmpty }) {
                if let text = Self.editingText { text.undoManager?.undo() } else if let last = e.history.first { e.restore(last) }
            },
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])

        add("View", [
            cmd("show-sound") { [weak self] in self?.show(.sound) },
            cmd("show-recordings") { [weak self] in self?.show(.recordings) },
            cmd("show-settings") { [weak self] in self?.show(.settings) },
            .separator(),
            cmd("see-voice", on: { e.monitoring }, when: driver) { [weak self] in
                if !e.monitoring { self?.show(.sound) }
                e.monitoring.toggle()
            },
            cmd("heat-map", on: { Engine.heatMap }) { Engine.heatMap.toggle() },
        ])

        add("Microphone", [
            cmd(MenuCommand.mute, "Mute", title: { e.muted ? "Unmute" : "Mute" }, when: driver) { e.muted.toggle() },
            cmd("listen", on: { e.listenBack }, when: driver) { e.listenBack.toggle() },
            .separator(),
            sub("Input", inputs),
            cmd("system-mic", on: { e.isSystemMicrophone }, when: driver) { e.setSystemMicrophone(!e.isSystemMicrophone) },
            .separator(),
            cmd("gain-up", when: { e.micGain != nil }) { if let g = e.micGain { e.setMicGain(g.db + 1) } },
            cmd("gain-down", when: { e.micGain != nil }) { if let g = e.micGain { e.setMicGain(g.db - 1) } },
            cmd("gain-lock", on: { e.gainLockDB != nil }, when: { e.micGain != nil }) { e.setGainLock(e.gainLockDB == nil) },
            .separator(),
            cmd("rename-mic", when: { e.canRenameMic }) { [weak self] in self?.show(.settings, then: .focusMicName) },
        ])

        let compressor = NSMenu(title: "Compressor Setting")
        for p in DynamicsView.compPresets { compressor.addItem(ActionItem(p.name) { p.apply(&e.dynamics) }) }
        let types = NSMenu(title: "Type")
        for t in BandType.allCases {
            types.addItem(ActionItem(t.label, on: { e.selectedBandIndex.map { e.bands[$0].type == t } ?? false }, when: band) { e.editSelectedBand { $0.type = t } })
        }
        add("Sound", [
            cmd("eq", on: { !e.bypass }) { e.bypass.toggle() },
            sub("Curve", NSMenu(title: "Curve"), [
                cmd("curve-warm", "Warm Voice", on: { e.bands == Presets.warm }) { e.bands = Presets.warm },
                cmd("curve-flat", "Flat", on: { e.bands == Presets.flat }) { e.bands = Presets.flat },
            ]),
            sub("Earlier Curves", curves),
            cmd("clear-history", when: { !e.history.isEmpty }) { e.clearHistory() },
            sub("Band", NSMenu(title: "Band"), [
                cmd("band-add", when: { e.bands.count < DSPChain.maxBands }) { [weak self] in self?.show(.sound); e.addBand() },
                cmd("band-next", when: { !e.bands.isEmpty }) { [weak self] in self?.show(.sound); e.selectBand(step: 1) },
                cmd("band-previous", when: { !e.bands.isEmpty }) { [weak self] in self?.show(.sound); e.selectBand(step: -1) },
                .separator(),
                cmd("band-on", on: { e.selectedBandIndex.map { e.bands[$0].on } ?? false }, when: band) { e.editSelectedBand { $0.on.toggle() } },
                sub("Type", types),
                cmd("band-gain-up", when: gainBand) { e.editSelectedBand { $0.gainDB = (($0.gainDB + 0.5) * 10).rounded() / 10 } },
                cmd("band-gain-down", when: gainBand) { e.editSelectedBand { $0.gainDB = (($0.gainDB - 0.5) * 10).rounded() / 10 } },
                // A twelfth of an octave, and a tenth narrower or wider, per press.
                cmd("band-freq-up", when: band) { e.editSelectedBand { $0.freq *= pow(2, 1.0 / 12) } },
                cmd("band-freq-down", when: band) { e.editSelectedBand { $0.freq /= pow(2, 1.0 / 12) } },
                cmd("band-wider", when: band) { e.editSelectedBand { $0.q /= 1.1 } },
                cmd("band-narrower", when: band) { e.editSelectedBand { $0.q *= 1.1 } },
                .separator(),
                cmd("band-remove", when: band) { e.removeSelectedBand() },
            ]),
            .separator(),
            cmd("gate", on: { e.dynamics.gateOn }) { e.dynamics.gateOn.toggle() },
            cmd("compressor", on: { e.dynamics.compOn }) { e.dynamics.compOn.toggle() },
            sub("Compressor Setting", compressor),
            cmd("limiter", on: { e.dynamics.limiterOn }) { e.dynamics.limiterOn.toggle() },
            .separator(),
            cmd("output-up") { e.outputGainDB = min(e.outputGainDB + 1, 12) },
            cmd("output-down") { e.outputGainDB = max(e.outputGainDB - 1, -12) },
            .separator(),
            sub("Presets", presets),
            cmd("save-preset") { [weak self] in self?.savePreset() },
            sub("Replace Preset", replace),
            sub("Delete Preset", delete),
        ])

        add("Recordings", [
            cmd(MenuCommand.record, "Start Recording", title: { e.recording ? "Stop Recording" : "Start Recording" }, when: driver) { e.toggleRecording() },
            .separator(),
            cmd("play-last") { [weak self] in
                guard let r = e.loadRecordings().first else { e.error = "There are no recordings to play yet."; return }
                self?.show(.recordings)
                e.play(r)
            },
            sub("Play", play),
            cmd("stop-playing", when: { e.auditioning != nil || Playback.shared.playing != nil }) { e.stopPlaying() },
            cmd("loop", on: { e.auditionLoop }) { e.auditionLoop.toggle() },
            .separator(),
            cmd("reveal-last") {
                if let r = e.loadRecordings().first { NSWorkspace.shared.activateFileViewerSelecting([r.url]) } else { e.error = "There are no recordings to show yet." }
            },
            cmd("open-folder") { NSWorkspace.shared.open(e.recordingsURL) },
            cmd("choose-folder") { e.chooseRecordingsFolder() },
        ])

        NSApp.windowsMenu = add("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            .separator(),
            cmd("show-window", "\(Brand.short) Window") { [weak self] in self?.openEditor() },
            NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""),
        ])

        NSApp.helpMenu = add("Help", [
            ActionItem("\(Brand.short) on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/artisticmedic/no-orange-dot")!) },
            ActionItem("Report a Problem…") { NSWorkspace.shared.open(URL(string: CrashReport.issues)!) },
        ])
        NSApp.mainMenu = main
        refresh()
    }

    /// Puts the user's shortcuts on the menu items, and keeps the preset list current so a preset's
    /// shortcut works before its menu has been opened.
    func refresh() {
        let e = engine
        let now = [e.muteShortcut, e.recordShortcut] + e.shortcuts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + e.presets.map { "preset:\($0.name)" }
        guard now != applied else { return }
        applied = now
        presets.removeAllItems()
        for (i, preset) in e.presets.enumerated() {
            let item = ActionItem(preset.name, on: { e.currentPreset?.id == preset.id }) { e.use(preset) }
            if i < 9 { items["preset-\(i + 1)"] = item }
            presets.addItem(item)
        }
        for i in e.presets.count..<max(e.presets.count, 9) { items["preset-\(i + 1)"] = nil }
        if e.presets.isEmpty { presets.addItem(ActionItem("No presets saved", when: { false }) {}) }
        for (id, item) in items {
            let s = Shortcut(e.shortcut(for: id))
            item.keyEquivalent = s?.menuKey ?? ""
            item.keyEquivalentModifierMask = s?.menuModifiers ?? []
        }
    }

    /// The name of whatever already uses a shortcut, so the same keys are not given to two things.
    func holder(of shortcut: Shortcut, except id: String) -> String? {
        for c in MenuCommand.all where c.id != id && Shortcut(engine.shortcut(for: c.id)) == shortcut { return c.title }
        let ours = Set(items.values.map(ObjectIdentifier.init))
        func search(_ menu: NSMenu) -> String? {
            for item in menu.items {
                if let found = item.submenu.flatMap(search) { return found }
                guard !ours.contains(ObjectIdentifier(item)), !item.keyEquivalent.isEmpty else { continue }
                var mods = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
                if item.keyEquivalent != item.keyEquivalent.lowercased() { mods.insert(.shift) }
                if item.keyEquivalent.lowercased() == shortcut.menuKey, mods == shortcut.menuModifiers { return item.title }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// Lists that change are filled in when their menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let e = engine
        menu.removeAllItems()
        func none(_ text: String) { menu.addItem(ActionItem(text, when: { false }) {}) }
        if menu === inputs {
            for input in e.inputs {
                menu.addItem(ActionItem(input.name, on: { e.inputUID == input.uid }) { e.inputUID = input.uid })
            }
            if e.inputs.isEmpty { none("No microphone found") }
        } else if menu === replace {
            for preset in e.presets { menu.addItem(ActionItem(preset.name) { e.savePreset(named: preset.name) }) }
            if e.presets.isEmpty { none("No presets saved") }
        } else if menu === delete {
            for preset in e.presets { menu.addItem(ActionItem(preset.name) { e.deletePreset(preset) }) }
            if e.presets.isEmpty { none("No presets saved") }
        } else if menu === curves {
            for s in e.history.prefix(20) {
                menu.addItem(ActionItem("\(s.date.formatted(date: .abbreviated, time: .shortened))  ·  \(s.summary)") { e.restore(s) })
            }
            if e.history.isEmpty { none("No earlier curves yet") }
        } else if menu === play {
            for r in e.loadRecordings().prefix(12) {
                menu.addItem(ActionItem("\(Recording.friendly(r.date))  ·  \(Recording.clock(r.seconds))") { [weak self] in self?.show(.recordings); e.play(r) })
            }
            if e.recordings.isEmpty { none("No recordings yet") }
        }
    }

    private static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Command line tool"
        alert.informativeText = message
        alert.runModal()
    }

    private static func cliTool(_ change: () -> String?) {
        let problem = change()
        NotificationCenter.default.post(name: .cliToolChanged, object: nil)
        report(problem ?? (CLITool.state == .installed ? "Installed at \(CLITool.link)." : "Removed."))
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
        guard !name.isEmpty else { return }
        if let i = engine.presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let confirm = NSAlert()
            confirm.messageText = "Replace the preset “\(engine.presets[i].name)”?"
            confirm.informativeText = "A preset with this name exists. Saving replaces it with the current sound."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        engine.savePreset(named: name)
    }
}
