import Foundation

/// The sound saved for one microphone.
struct MicProfile: Codable, Equatable {
    var name = ""
    var equalizer = true
    var outputGainDB = 0.0
    var bands: [Band] = Presets.flat
    var dynamics = Dynamics()
    /// When set, the app holds the mic's own preamp gain at this value and puts it back if anything else moves it.
    var gainLockDB: Double?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainLockDB = try c.decodeIfPresent(Double.self, forKey: .gainLockDB)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        equalizer = try c.decodeIfPresent(Bool.self, forKey: .equalizer) ?? true
        outputGainDB = try c.decodeIfPresent(Double.self, forKey: .outputGainDB) ?? 0
        bands = try c.decodeIfPresent([Band].self, forKey: .bands) ?? Presets.flat
        dynamics = try c.decodeIfPresent(Dynamics.self, forKey: .dynamics) ?? Dynamics()
    }
}

/// A whole sound saved under a name: EQ, gate, compressor, limiter and output level. Presets belong to no
/// one microphone, so the same one can be tried on any of them or on a recording.
struct SoundPreset: Codable, Identifiable, Equatable {
    var id = UUID()   // in-memory only
    var name: String
    var equalizer = true
    var outputGainDB = 0.0
    var bands: [Band]
    var dynamics = Dynamics()

    enum CodingKeys: String, CodingKey { case name, equalizer, outputGainDB, bands, dynamics }

    init(name: String, from p: MicProfile) {
        self.name = name; equalizer = p.equalizer; outputGainDB = p.outputGainDB; bands = p.bands; dynamics = p.dynamics
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        equalizer = try c.decodeIfPresent(Bool.self, forKey: .equalizer) ?? true
        outputGainDB = try c.decodeIfPresent(Double.self, forKey: .outputGainDB) ?? 0
        bands = try c.decodeIfPresent([Band].self, forKey: .bands) ?? Presets.flat
        dynamics = try c.decodeIfPresent(Dynamics.self, forKey: .dynamics) ?? Dynamics()
    }

    /// True when a microphone's sound is exactly this preset.
    func matches(_ p: MicProfile) -> Bool {
        equalizer == p.equalizer && outputGainDB == p.outputGainDB && bands == p.bands && dynamics == p.dynamics
    }

    func apply(to p: inout MicProfile) {
        p.equalizer = equalizer; p.outputGainDB = outputGainDB; p.bands = bands; p.dynamics = dynamics
    }

    /// "5 bands · gate · compressor"
    var summary: String {
        let on = bands.filter(\.on).count
        var parts = [equalizer ? "\(on) band\(on == 1 ? "" : "s")" : "EQ off"]
        if dynamics.gateOn { parts.append("gate") }
        if dynamics.compOn { parts.append("compressor") }
        if dynamics.limiterOn { parts.append("limiter") }
        if outputGainDB != 0 { parts.append(String(format: "%+.1f dB", outputGainDB)) }
        return parts.joined(separator: " · ")
    }

    static func == (a: SoundPreset, b: SoundPreset) -> Bool {
        a.name == b.name && a.equalizer == b.equalizer && a.outputGainDB == b.outputGainDB && a.bands == b.bands && a.dynamics == b.dynamics
    }

    /// Adds the preset, or replaces the one with the same name.
    static func save(_ preset: SoundPreset, in list: inout [SoundPreset]) {
        if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) { list[i] = preset } else { list.append(preset) }
    }

    /// Finds a preset by its number in the list (from 1) or by name.
    static func index(of key: String, in list: [SoundPreset]) -> Int? {
        if let n = Int(key), list.indices.contains(n - 1) { return n - 1 }
        return list.firstIndex { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }
}

/// Everything the app remembers. It lives in config.json, which is the source of truth: the app
/// writes it when you change something, and re-reads it when anything else (you, a script, an
/// agent) edits it. Missing keys fall back to defaults so a partial file is valid.
///
/// Each microphone keeps its own sound in `mics`, keyed by the device's ID. `inputUID` says which
/// microphone is in use, and so which entry is live.
struct Settings: Codable, Equatable {
    var muted = false
    var inputUID = ""
    /// The microphone you chose, while it is unplugged and `inputUID` names a stand-in. Empty otherwise.
    var returnToUID = ""
    var icon = "eclipse"
    /// Which Dock icon the app wears while it runs: "paint" or "carbon".
    var appIcon = "paint"
    /// Keep a Dock icon while the window is closed. Off means the app lives in the menu bar only.
    var showInDock = false
    /// System-wide shortcuts, written like "ctrl+opt+cmd+m". Empty means none. The app ships with none set.
    var muteShortcut = ""
    var recordShortcut = ""
    /// Shortcuts for menu commands, by command ID. They work while the app is in front.
    var shortcuts: [String: String] = [:]
    /// Look for a new version once a day.
    var autoUpdate = true
    /// Where to look for it. Empty means the built-in address.
    var updateFeed = ""
    /// Where recordings are saved and listed from. Empty means ~/Music/No Orange Dot.
    var recordingsFolder = ""
    /// The name apps show for the virtual mic. Empty means the built-in name.
    var micName = ""
    var mics: [String: MicProfile] = [:]
    /// Saved sounds, in the order they are listed.
    var presets: [SoundPreset] = []

    func shortcut(for id: String) -> String {
        id == MenuCommand.mute ? muteShortcut : id == MenuCommand.record ? recordShortcut : shortcuts[id] ?? ""
    }

    mutating func setShortcut(_ text: String, for id: String) {
        if id == MenuCommand.mute { muteShortcut = text }
        else if id == MenuCommand.record { recordShortcut = text }
        else { shortcuts[id] = text.isEmpty ? nil : text }
    }

    /// The name of whatever already uses these keys, other than the command being set.
    func holder(of shortcut: Shortcut, except id: String) -> String? {
        if let standard = MenuCommand.reserved[shortcut.text] { return standard }
        return MenuCommand.all.first { $0.id != id && Shortcut(self.shortcut(for: $0.id)) == shortcut }?.title
    }

    /// The sound for the microphone in use.
    var active: MicProfile {
        get { mics[inputUID] ?? MicProfile() }
        set { mics[inputUID] = newValue }
    }

    private enum LegacyKeys: String, CodingKey { case equalizer, outputGainDB, bands, dynamics }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        inputUID = try c.decodeIfPresent(String.self, forKey: .inputUID) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "eclipse"
        appIcon = try c.decodeIfPresent(String.self, forKey: .appIcon) ?? "paint"
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        muteShortcut = try c.decodeIfPresent(String.self, forKey: .muteShortcut) ?? ""
        recordShortcut = try c.decodeIfPresent(String.self, forKey: .recordShortcut) ?? ""
        shortcuts = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? [:]
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        presets = try c.decodeIfPresent([SoundPreset].self, forKey: .presets) ?? []
        returnToUID = try c.decodeIfPresent(String.self, forKey: .returnToUID) ?? ""
        updateFeed = try c.decodeIfPresent(String.self, forKey: .updateFeed) ?? ""
        mics = try c.decodeIfPresent([String: MicProfile].self, forKey: .mics) ?? [:]
        recordingsFolder = try c.decodeIfPresent(String.self, forKey: .recordingsFolder) ?? ""
        micName = try c.decodeIfPresent(String.self, forKey: .micName) ?? ""
        // Files from before per-microphone sound kept one set of values at the top level.
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        if mics[inputUID] == nil, let bands = try old.decodeIfPresent([Band].self, forKey: .bands) {
            var p = MicProfile()
            p.bands = bands
            p.equalizer = try old.decodeIfPresent(Bool.self, forKey: .equalizer) ?? true
            p.outputGainDB = try old.decodeIfPresent(Double.self, forKey: .outputGainDB) ?? 0
            p.dynamics = try old.decodeIfPresent(Dynamics.self, forKey: .dynamics) ?? Dynamics()
            mics[inputUID] = p
        }
    }

    static let historyFile = directory.appendingPathComponent("history.json")
    /// NOD_HOME points the app and the CLI at another folder, so tests never touch the real settings.
    static let directory: URL = ProcessInfo.processInfo.environment["NOD_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoOrangeDot")
    static let file = directory.appendingPathComponent("config.json")
    static let statusFile = directory.appendingPathComponent("status.json")

    var recordingsURL: URL {
        recordingsFolder.isEmpty
            ? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent(Brand.short)
            : URL(fileURLWithPath: (recordingsFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    enum LoadResult { case missing, ok(Settings), invalid(String) }

    static func load() -> LoadResult {
        guard let data = try? Data(contentsOf: file) else { return .missing }
        do { return .ok(try JSONDecoder().decode(Settings.self, from: data)) }
        catch { return .invalid("config.json has an error, so it is being ignored: \(Self.describe(error))") }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(self) { try? data.write(to: Self.file, options: .atomic) }
    }

    static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): return c.debugDescription
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c), DecodingError.keyNotFound(_, let c):
            return "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
        default: return error.localizedDescription
        }
    }
}

/// What the app is doing right now, written to status.json for scripts and agents to read.
struct Status: Codable, Equatable {
    var driverInstalled = false
    var micOpen = false
    var appListening = false
    var systemMicrophone = false
    var muted = false
    var recording = false
    var input = ""
    var sampleRate = 0.0
    var lastWakeMs: Double?
    var lastRecording: String?
    var problem: String?
    var usedBy: [String] = []
    var micName = ""
    var playing: String?

    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(self) { try? data.write(to: Settings.statusFile, options: .atomic) }
    }
}

enum Command {
    static let name = Notification.Name("\(Brand.bundleID).command")
    static func send(_ verb: String) {
        DistributedNotificationCenter.default().postNotificationName(name, object: verb, userInfo: nil, deliverImmediately: true)
    }
}

/// One earlier EQ curve, kept so a change can be taken back. Saved in history.json.
struct EQSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var mic: String
    var bands: [Band]

    enum CodingKeys: String, CodingKey { case date, mic, bands }

    /// "3 bands · low shelf +2.9, bell −2.5"
    var summary: String {
        let on = bands.filter(\.on)
        let moves = on.filter { $0.gainDB != 0 }.prefix(3).map { "\($0.type.label.lowercased()) \(String(format: "%+.1f", $0.gainDB))" }
        return "\(on.count) band\(on.count == 1 ? "" : "s")" + (moves.isEmpty ? "" : " · " + moves.joined(separator: ", "))
    }

    static func load() -> [EQSnapshot] {
        guard let data = try? Data(contentsOf: Settings.historyFile) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([EQSnapshot].self, from: data)) ?? []
    }

    static func save(_ list: [EQSnapshot]) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try? e.encode(list).write(to: Settings.historyFile, options: .atomic)
    }
}
