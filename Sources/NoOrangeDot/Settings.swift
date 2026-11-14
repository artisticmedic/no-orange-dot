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
    /// System-wide shortcuts, written like "ctrl+opt+cmd+m". Empty means none.
    var muteShortcut = "ctrl+opt+cmd+m"
    var recordShortcut = "ctrl+opt+cmd+r"
    /// Look for a new version once a day.
    var autoUpdate = true
    /// Where to look for it. Empty means the built-in address.
    var updateFeed = ""
    /// Where recordings are saved and listed from. Empty means ~/Music/No Orange Dot.
    var recordingsFolder = ""
    /// The name apps show for the virtual mic. Empty means the built-in name.
    var micName = ""
    var mics: [String: MicProfile] = [:]

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
        muteShortcut = try c.decodeIfPresent(String.self, forKey: .muteShortcut) ?? "ctrl+opt+cmd+m"
        recordShortcut = try c.decodeIfPresent(String.self, forKey: .recordShortcut) ?? "ctrl+opt+cmd+r"
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
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
