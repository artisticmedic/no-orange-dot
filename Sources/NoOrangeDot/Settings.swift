import Darwin
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

/// A whole sound saved under a name: EQ, gate, compressor, de-esser, limiter and output level. Presets belong to no
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
        if dynamics.deessOn { parts.append("de-esser") }
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

    /// Exact names win over positions, so an older preset named "2" still selects itself.
    static func index(of key: String, in list: [SoundPreset]) -> Int? {
        if let named = list.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return named }
        if let n = Int(key), n >= 1, n <= list.count { return n - 1 }
        return nil
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
    /// Included microphones, from most to least preferred. Other inputs are used only when none are connected.
    var micOrder: [String] = []
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

    /// A manual choice leaves priority membership and ordering unchanged.
    mutating func selectInput(_ uid: String) { inputUID = uid }

    mutating func includeMic(_ uid: String, included: Bool) {
        if included {
            if !micOrder.contains(uid) { micOrder.append(uid) }
        } else {
            micOrder.removeAll { $0 == uid }
        }
    }

    /// Moves a microphone to a place in the order, counted from 1.
    mutating func moveMic(_ uid: String, to place: Int) {
        guard micOrder.contains(uid) else { return }
        micOrder.removeAll { $0 == uid }
        micOrder.insert(uid, at: min(max(place - 1, 0), micOrder.count))
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

    private enum LegacyKeys: String, CodingKey { case equalizer, outputGainDB, bands, dynamics, returnToUID }

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
        micOrder = try c.decodeIfPresent([String].self, forKey: .micOrder) ?? []
        updateFeed = try c.decodeIfPresent(String.self, forKey: .updateFeed) ?? ""
        mics = try c.decodeIfPresent([String: MicProfile].self, forKey: .mics) ?? [:]
        recordingsFolder = try c.decodeIfPresent(String.self, forKey: .recordingsFolder) ?? ""
        micName = try c.decodeIfPresent(String.self, forKey: .micName) ?? ""
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        // Files from before the order kept the chosen microphone in returnToUID while a stand-in was in use.
        if !c.contains(.micOrder) {
            let chosen = try old.decodeIfPresent(String.self, forKey: .returnToUID) ?? ""
            for uid in [chosen, inputUID] where !uid.isEmpty && !micOrder.contains(uid) { micOrder.append(uid) }
        }
        var seen = Set<String>()
        micOrder = micOrder.filter { !$0.isEmpty && seen.insert($0).inserted }
        // Files from before per-microphone sound kept one set of values at the top level.
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
    static let store = SettingsStore(file: file)

    var recordingsURL: URL {
        recordingsFolder.isEmpty
            ? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent(Brand.short)
            : URL(fileURLWithPath: (recordingsFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    enum LoadResult { case missing, ok(Settings), invalid(String) }

    static func load() -> LoadResult {
        do {
            let snapshot = try store.read()
            return snapshot.revision == nil ? .missing : .ok(snapshot.settings)
        } catch { return .invalid(error.localizedDescription) }
    }

    fileprivate static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): return c.debugDescription
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c), DecodingError.keyNotFound(_, let c):
            return "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
        default: return error.localizedDescription
        }
    }
}

struct SettingsStore {
    struct Snapshot {
        var settings: Settings
        let revision: Data?
    }

    enum Failure: LocalizedError {
        case changed
        case read(Error)
        case invalid(Error)
        case write(Error)

        var errorDescription: String? {
            switch self {
            case .changed: return "config.json changed outside the app. The newer settings were kept; try your change again."
            case .read(let error): return "Couldn't read config.json: \(error.localizedDescription)"
            case .invalid(let error): return "config.json has an error, so it is being ignored: \(Settings.describe(error))"
            case .write(let error): return "Couldn't save config.json: \(error.localizedDescription)"
            }
        }
    }

    let file: URL

    func read() throws -> Snapshot {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Snapshot(settings: Settings(), revision: nil) }
        catch { throw Failure.read(error) }
        do { return Snapshot(settings: try JSONDecoder().decode(Settings.self, from: data), revision: data) }
        catch { throw Failure.invalid(error) }
    }

    /// GUI and CLI writers share a lock; hand edits are checked against the exact bytes that were loaded.
    func save(_ settings: Settings, expecting revision: Data?) throws -> Snapshot {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        let directory = file.deletingLastPathComponent()
        do {
            data = try encoder.encode(settings)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { throw Failure.write(error) }
        let lock = open(directory.appendingPathComponent("config.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.write(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.write(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
        defer { flock(lock, LOCK_UN) }
        guard try read().revision == revision else { throw Failure.changed }
        do { try data.write(to: file, options: .atomic) }
        catch { throw Failure.write(error) }
        return Snapshot(settings: settings, revision: data)
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
    var micUID: String? = nil

    enum CodingKeys: String, CodingKey { case date, mic, bands, micUID }

    /// "3 bands · low shelf +2.9, bell −2.5"
    var summary: String {
        let on = bands.filter(\.on)
        let moves = on.filter { $0.gainDB != 0 }.prefix(3).map { "\($0.type.label.lowercased()) \(String(format: "%+.1f", $0.gainDB))" }
        return "\(on.count) band\(on.count == 1 ? "" : "s")" + (moves.isEmpty ? "" : " · " + moves.joined(separator: ", "))
    }

    struct Archive {
        let snapshots: [EQSnapshot]
        let revision: Data?
    }

    enum Failure: LocalizedError {
        case changed
        case read(Error)
        case invalid(Error)
        case write(Error)

        var errorDescription: String? {
            switch self {
            case .changed: return "history.json changed outside the app. The newer earlier curves were kept."
            case .read(let error): return "Couldn't read history.json: \(error.localizedDescription)"
            case .invalid(let error): return "history.json has an error and was left untouched: \(error.localizedDescription)"
            case .write(let error): return "Couldn't save history.json: \(error.localizedDescription)"
            }
        }
    }

    static func load() -> [EQSnapshot] { (try? read().snapshots) ?? [] }

    static func read(from file: URL = Settings.historyFile) throws -> Archive {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Archive(snapshots: [], revision: nil) }
        catch { throw Failure.read(error) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return Archive(snapshots: try decoder.decode([EQSnapshot].self, from: data), revision: data) }
        catch { throw Failure.invalid(error) }
    }

    static func save(_ list: [EQSnapshot], expecting revision: Data?, to file: URL = Settings.historyFile) throws -> Archive {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        let directory = file.deletingLastPathComponent()
        do {
            data = try encoder.encode(list)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { throw Failure.write(error) }
        let lock = open(directory.appendingPathComponent("history.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.write(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.write(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
        defer { flock(lock, LOCK_UN) }
        guard try read(from: file).revision == revision else { throw Failure.changed }
        do { try data.write(to: file, options: .atomic) }
        catch { throw Failure.write(error) }
        return Archive(snapshots: list, revision: data)
    }
}
