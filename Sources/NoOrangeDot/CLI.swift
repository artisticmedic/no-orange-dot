import Foundation

/// Command-line control, so scripts and agents can do everything the windows can.
/// Settings verbs edit config.json, which the running app re-reads within half a second.
enum CLI {
    static let verbs: Set<String> = ["status", "get", "mute", "eq", "preset", "band", "gate", "comp", "input", "output", "mics", "name", "play", "auto-eq", "recordings", "cli", "record", "system", "icon", "appicon", "dock", "gain", "listen", "limiter", "shortcut", "history", "open", "help", "--help", "-h"]

    static let help = """
    nod: control \(Brand.name)

      nod status                         what the app is doing now, as JSON
      nod get                            all settings, as JSON
      nod mute on|off|toggle
      nod eq on|off
      nod preset warm|flat
      nod band list
      nod band set <n> [type=bell] [freq=480] [gain=-3] [q=0.7] [on=true]
      nod band add type=bell freq=1000 [gain=0] [q=1]
      nod band remove <n>
      nod gate on|off [threshold=-50] [range=-30]
      nod comp on|off [threshold=-18] [ratio=3] [attack=8] [release=150] [makeup=0]
      nod limiter on|off [ceiling=-1]    catch peaks before they clip
      nod record start|stop|toggle
      nod shortcut mute|record <keys>|off   system-wide shortcut, e.g. ctrl+opt+cmd+m
      nod auto-eq measure [seconds=20] [target=warm] [strength=1] [apply]
                                         listen to the mic, then suggest an EQ (speak the whole time)
      nod auto-eq match <reference audio> <this mic's audio> [strength=1] [apply] [out=<wav>]
                                         make this mic sound like the reference. Both should be the same words.
      nod auto-eq file <audio> [target=warm|neutral|bright] [strength=1] [apply] [out=<wav>] [curves]
                                         work out an EQ from a recording of speech
      nod input list | nod input <name>
      nod mics                           microphones that have a saved sound
      nod output <dB>
      nod play <name> | nod play stop    replay a recording's raw take through the current EQ, looped
      nod name [<text>|reset]            show or change the name apps see for the mic
      nod recordings                     list recordings, newest first
      nod recordings folder [<path>]     show or change where they are saved and listed from
      nod recordings delete <name>       move one recording to the Trash
      nod recordings clear               move them all to the Trash
      nod system on|off                  make it the Mac's input, or put the old one back
      nod icon eclipse|ring|halo|capsule|nodot|symbol   the menu bar mark
      nod appicon paint|carbon           the Dock icon while the app is running
      nod listen on|off                  hear your own processed voice in your headphones
      nod gain [dB]                      the real mic's own preamp gain, when the hardware allows it
      nod gain lock|unlock               hold the gain there; put it back if another app moves it
      nod history                        earlier EQ curves, newest first
      nod history restore <n>            bring one back
      nod history clear
      nod dock on|off                    keep a Dock icon while the window is closed
      nod open                           open the editor window
      nod cli status|install|remove|test put this command on your path, and check it works

    Each microphone keeps its own EQ, gate, compressor and output level. The eq, preset, band,
    gate, comp and output commands change the microphone in use.

    Band types: highPass, lowShelf, bell, highShelf, lowPass. Bands are numbered from 1.
    Settings live in \(Settings.file.path)
    """

    static func run(_ args: [String]) -> Int32 {
        guard let verb = args.first else { print(help); return 0 }
        let rest = Array(args.dropFirst())
        switch verb {
        case "help", "--help", "-h": print(help); return 0
        case "status":
            guard let s = try? String(contentsOf: Settings.statusFile, encoding: .utf8) else { return fail("The app hasn't written a status yet. Is it running?") }
            print(s); return 0
        case "get": return edit { _ in }.flatMap { _ in printSettings() } ?? 1
        case "record":
            guard let a = rest.first, a == "start" || a == "stop" || a == "toggle" else { return fail("Use: nod record start|stop|toggle") }
            Command.send("record-\(a)"); return settle()
        case "open": Command.send("open-editor"); return 0
        case "auto-eq":
            if rest.first == "measure" {
                var seconds = 20.0, target = "warm", strength = 1.0, mode = "keep"
                for a in rest.dropFirst() {
                    if a == "apply" { mode = "apply"; continue }
                    let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { return fail("Expected key=value, got \"\(a)\"") }
                    switch kv[0] {
                    case "seconds": guard let v = Double(kv[1]), (5...60).contains(v) else { return fail("seconds must be from 5 to 60") }; seconds = v
                    case "target": guard AutoEQ.Target(rawValue: kv[1]) != nil else { return fail("target must be warm, neutral or bright") }; target = kv[1]
                    case "strength": guard let v = Double(kv[1]), (0...1.5).contains(v) else { return fail("strength must be from 0 to 1.5") }; strength = v
                    default: return fail("Unknown option \"\(kv[0])\"")
                    }
                }
                let out = Settings.directory.appendingPathComponent("autoeq.json")
                let before = (try? FileManager.default.attributesOfItem(atPath: out.path))?[.modificationDate] as? Date
                Command.send("autoeq-measure \(seconds) \(target) \(strength) \(mode)")
                let deadline = Date().addingTimeInterval(seconds + 15)
                while Date() < deadline {
                    usleep(250_000)
                    let now = (try? FileManager.default.attributesOfItem(atPath: out.path))?[.modificationDate] as? Date
                    if let now, now != before, let text = try? String(contentsOf: out, encoding: .utf8) { print(text); return text.contains("\"error\"") ? 1 : 0 }
                }
                return fail("The app didn't answer. Is it running, with the driver installed?")
            }
            if rest.first == "match" {
                guard rest.count > 2 else { return fail("Use: nod auto-eq match <reference audio> <this mic's audio> [strength=1] [apply] [out=<wav>]") }
                var strength = 1.0, applyIt = false, out: String?
                for a in rest.dropFirst(3) {
                    if a == "apply" { applyIt = true; continue }
                    let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { return fail("Expected key=value, got \"\(a)\"") }
                    switch kv[0] {
                    case "strength": guard let v = Double(kv[1]), (0...1.5).contains(v) else { return fail("strength must be from 0 to 1.5") }; strength = v
                    case "out": out = kv[1]
                    default: return fail("Unknown option \"\(kv[0])\"")
                    }
                }
                func load(_ path: String) -> (samples: [Float], sampleRate: Double, levels: [Double], seconds: Double)? {
                    guard let a = AutoEQ.read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)),
                          let m = AutoEQ.measure(a.samples, sampleRate: a.sampleRate) else { return nil }
                    return (a.samples, a.sampleRate, m.levels, m.seconds)
                }
                guard let ref = load(rest[1]) else { return fail("Couldn't measure speech in \(rest[1]).") }
                guard let mine = load(rest[2]) else { return fail("Couldn't measure speech in \(rest[2]).") }
                var result = AutoEQ.fit(levels: mine.levels, seconds: mine.seconds, target: .neutral, strength: strength, sampleRate: mine.sampleRate, reference: ref.levels)
                if let out, !AutoEQ.write(AutoEQ.apply(result.bands, to: mine.samples, sampleRate: mine.sampleRate), sampleRate: mine.sampleRate, to: URL(fileURLWithPath: out)) {
                    return fail("Couldn't write \(out).")
                }
                if applyIt, let r = edit({ $0.active.bands = result.bands; $0.active.equalizer = true }), r != 0 { return r }
                result.centres = []; result.measured = []; result.wanted = []
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let d = try? e.encode(result), let text = String(data: d, encoding: .utf8) { print(text) }
                return 0
            }
            guard rest.first == "file", rest.count > 1 else { return fail("Use: nod auto-eq file <audio> [target=warm|neutral|bright] [strength=1] [apply] [out=<wav>]") }
            var target = AutoEQ.Target.warm, strength = 1.0, applyIt = false, curves = false, out: String?
            for a in rest.dropFirst(2) {
                if a == "apply" { applyIt = true; continue }
                if a == "curves" { curves = true; continue }
                let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { return fail("Expected key=value, got \"\(a)\"") }
                switch kv[0] {
                case "target": guard let t = AutoEQ.Target(rawValue: kv[1]) else { return fail("target must be warm, neutral or bright") }; target = t
                case "strength": guard let v = Double(kv[1]), (0...1.5).contains(v) else { return fail("strength must be from 0 to 1.5") }; strength = v
                case "out": out = kv[1]
                default: return fail("Unknown option \"\(kv[0])\"")
                }
            }
            let url = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath)
            guard let audio = AutoEQ.read(url) else { return fail("Couldn't read \(url.path) as audio.") }
            guard let m = AutoEQ.measure(audio.samples, sampleRate: audio.sampleRate) else { return fail("There isn't enough speech in that recording, or it is very quiet. It needs a few seconds of talking at a normal level.") }
            var result = AutoEQ.fit(levels: m.levels, seconds: m.seconds, target: target, strength: strength, sampleRate: audio.sampleRate)
            if let out, !AutoEQ.write(AutoEQ.apply(result.bands, to: audio.samples, sampleRate: audio.sampleRate), sampleRate: audio.sampleRate, to: URL(fileURLWithPath: out)) {
                return fail("Couldn't write \(out).")
            }
            if applyIt, let r = edit({ $0.active.bands = result.bands; $0.active.equalizer = true }), r != 0 { return r }
            if !curves { result.centres = []; result.measured = []; result.wanted = [] }
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? e.encode(result), let text = String(data: d, encoding: .utf8) { print(text) }
            return 0
        case "recordings":
            if rest.first == "folder" {
                if rest.count > 1 {
                    let path = rest.dropFirst().joined(separator: " ")
                    if let r = edit({ $0.recordingsFolder = path }), r != 0 { return r }
                }
                guard case .ok(let s) = Settings.load() else { return fail("No settings file yet.") }
                print(s.recordingsURL.path); return 0
            }
            guard case .ok(let s) = Settings.load() else { return fail("No settings file yet.") }
            if rest.first == "delete" || rest.first == "clear" {
                var items = Recording.list(in: s.recordingsURL)
                if rest.first == "delete" {
                    let want = rest.dropFirst().joined(separator: " ")
                    items = items.filter { $0.url.lastPathComponent == want || $0.url.deletingPathExtension().lastPathComponent == want || $0.url.path == want }
                    guard !items.isEmpty else { return fail("No recording is named \"\(want)\". Try: nod recordings") }
                }
                for r in items {
                    try? FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
                    if let raw = r.raw { try? FileManager.default.trashItem(at: raw, resultingItemURL: nil) }
                }
                print("Moved \(items.count) \(items.count == 1 ? "recording" : "recordings") to the Trash")
                return 0
            }
            for r in Recording.list(in: s.recordingsURL) { print("\(Recording.clock(r.seconds))  \(r.url.path)") }
            return 0
        case "cli":
            switch rest.first {
            case "status":
                switch CLITool.state {
                case .installed: print("Installed at \(CLITool.link)")
                case .notInstalled: print("Not installed")
                case .pointsElsewhere(let w): print("\(CLITool.link) points at \(w), not this copy of the app")
                }
                return 0
            case "install": if let p = CLITool.install() { return fail(p) }; print("Installed at \(CLITool.link)"); return 0
            case "remove": if let p = CLITool.remove() { return fail(p) }; print("Removed \(CLITool.link)"); return 0
            case "test": let r = CLITool.test(); print(r.message); return r.ok ? 0 : 1
            default: return fail("Use: nod cli status|install|remove|test")
            }
        case "play":
            guard !rest.isEmpty else { return fail("Use: nod play <name>, or nod play stop") }
            Command.send(rest.first == "stop" ? "play-stop" : "play \(rest.joined(separator: " "))"); return settle()
        case "name":
            if let a = rest.first {
                let name = a == "reset" ? "" : rest.joined(separator: " ")
                if let r = edit({ $0.micName = name }), r != 0 { return r }
                return settle()
            }
            return run(["status"])
        case "mics":
            guard case .ok(let s) = Settings.load() else { return fail("No settings file yet.") }
            let names = Dictionary(HAL.inputDevices().map { ($0.uid, $0.name) }, uniquingKeysWith: { a, _ in a })
            for (uid, p) in s.mics.sorted(by: { $0.key < $1.key }) {
                print("\(uid == s.inputUID ? "*" : " ") \(names[uid] ?? (p.name.isEmpty ? uid : p.name))  (\(p.bands.filter(\.on).count) bands\(p.dynamics.gateOn ? ", gate" : "")\(p.dynamics.compOn ? ", compressor" : ""))")
            }
            return 0
        case "system":
            guard let a = rest.first, a == "on" || a == "off" else { return fail("Use: nod system on|off") }
            Command.send("system-\(a)"); return settle()
        case "shortcut":
            guard rest.count == 2, rest[0] == "mute" || rest[0] == "record" else { return fail("Use: nod shortcut mute|record <keys>|off, for example ctrl+opt+cmd+m") }
            let value = rest[1] == "off" ? "" : rest[1]
            if !value.isEmpty, Shortcut(value) == nil { return fail("Can't read \"\(value)\". Use a key with ctrl, opt or cmd, for example ctrl+opt+cmd+m, or a function key such as f13.") }
            let text = Shortcut(value)?.text ?? ""
            return done(edit { if rest[0] == "mute" { $0.muteShortcut = text } else { $0.recordShortcut = text } })
        case "listen":
            guard let a = rest.first, a == "on" || a == "off" else { return fail("Use: nod listen on|off") }
            Command.send("listen-\(a)"); return settle()
        case "gain":
            guard let uid = { () -> String? in if case .ok(let s) = Settings.load() { return s.inputUID }; return nil }(),
                  let dev = HAL.device(uid: uid), let g = HAL.inputGain(dev) else { return fail("This microphone doesn't let the Mac set its gain.") }
            guard let a = rest.first else { print(String(format: "%.1f dB (%.0f to %.0f)", g.db, g.min, g.max)); return 0 }
            if a == "lock" || a == "unlock" { Command.send("gain-\(a)"); usleep(700_000); return run(["get"]) == 0 ? 0 : 1 }
            guard let v = Double(a), v >= g.min, v <= g.max else { return fail(String(format: "Use a number from %.0f to %.0f.", g.min, g.max)) }
            Command.send("gain \(v)"); usleep(400_000)
            print(String(format: "%.1f dB", HAL.inputGain(dev)?.db ?? v)); return 0
        case "history":
            let list = EQSnapshot.load()
            switch rest.first {
            case nil:
                if list.isEmpty { print("No earlier curves yet.") }
                for (i, s) in list.enumerated() { print("\(i + 1)  \(s.date.formatted(date: .abbreviated, time: .shortened))  \(s.summary)") }
                return 0
            case "restore":
                guard rest.count > 1, let n = Int(rest[1]), list.indices.contains(n - 1) else { return fail("Use: nod history restore <n>, with a number from nod history") }
                Command.send("history-restore \(n)"); return settle()
            case "clear": Command.send("history-clear"); return 0
            default: return fail("Use: nod history, nod history restore <n>, or nod history clear")
            }
        case "appicon":
            guard let a = rest.first, a == "paint" || a == "carbon" else { return fail("Use: nod appicon paint|carbon") }
            return done(edit { $0.appIcon = a })
        case "dock":
            guard let a = rest.first, a == "on" || a == "off" else { return fail("Use: nod dock on|off") }
            return done(edit { $0.showInDock = a == "on" })
        case "icon":
            guard let a = rest.first, AppMark.Style(rawValue: a) != nil else { return fail("Use: nod icon eclipse|ring|halo|capsule|nodot|symbol") }
            return done(edit { $0.icon = a })
        case "input":
            let devices = HAL.inputDevices()
            guard let a = rest.first else { return fail("Use: nod input list, or nod input <name>") }
            if a == "list" { devices.forEach { print($0.name) }; return 0 }
            let want = rest.joined(separator: " ").lowercased()
            guard let d = devices.first(where: { $0.name.lowercased() == want }) ?? devices.first(where: { $0.name.lowercased().contains(want) }) else {
                return fail("No microphone matches \"\(rest.joined(separator: " "))\". Try: nod input list")
            }
            return done(edit { $0.inputUID = d.uid })
        default: break
        }

        let result: Int32? = edit { s in
            switch verb {
            case "mute":
                switch rest.first { case "on": s.muted = true; case "off": s.muted = false; case "toggle": s.muted.toggle(); default: throw Bad("Use: nod mute on|off|toggle") }
            case "eq": s.active.equalizer = try onOff(rest.first, "nod eq on|off")
            case "preset":
                switch rest.first { case "warm": s.active.bands = Presets.warm; case "flat": s.active.bands = Presets.flat; default: throw Bad("Use: nod preset warm|flat") }
            case "output":
                guard let v = rest.first.flatMap(Double.init), (-12...12).contains(v) else { throw Bad("Use: nod output <dB>, from -12 to 12") }
                s.active.outputGainDB = v
            case "gate":
                s.active.dynamics.gateOn = try onOff(rest.first, "nod gate on|off [threshold=-50] [range=-30] [hold=120] [release=180]")
                for (k, v) in try pairs(rest.dropFirst()) {
                    switch k { case "threshold": s.active.dynamics.gateThresholdDB = try num(v); case "range": s.active.dynamics.gateRangeDB = try num(v); case "hold": s.active.dynamics.gateHoldMs = try num(v); case "release": s.active.dynamics.gateReleaseMs = try num(v); default: throw Bad("Unknown gate setting \"\(k)\"") }
                }
            case "limiter":
                s.active.dynamics.limiterOn = try onOff(rest.first, "nod limiter on|off [ceiling=-1]")
                for (k, v) in try pairs(rest.dropFirst()) {
                    switch k { case "ceiling": s.active.dynamics.limiterCeilingDB = min(try num(v), 0); default: throw Bad("Unknown limiter setting \"\(k)\"") }
                }
            case "comp":
                s.active.dynamics.compOn = try onOff(rest.first, "nod comp on|off [threshold=-18] [ratio=3] [attack=8] [release=150] [makeup=0]")
                for (k, v) in try pairs(rest.dropFirst()) {
                    switch k {
                    case "threshold": s.active.dynamics.compThresholdDB = try num(v)
                    case "ratio": s.active.dynamics.compRatio = try num(v)
                    case "attack": s.active.dynamics.compAttackMs = try num(v)
                    case "release": s.active.dynamics.compReleaseMs = try num(v)
                    case "makeup": s.active.dynamics.compMakeupDB = try num(v)
                    default: throw Bad("Unknown compressor setting \"\(k)\"")
                    }
                }
            case "band":
                switch rest.first {
                case "list": break
                case "add":
                    guard s.active.bands.count < DSPChain.maxBands else { throw Bad("There are already \(DSPChain.maxBands) bands, which is the most allowed.") }
                    var b = Band(type: .bell, freq: 1000, gainDB: 0, q: 1)
                    try apply(try pairs(rest.dropFirst()), to: &b); s.active.bands.append(b)
                case "set":
                    let i = try index(rest.dropFirst().first, s.active.bands.count)
                    try apply(try pairs(rest.dropFirst(2)), to: &s.active.bands[i])
                case "remove": s.active.bands.remove(at: try index(rest.dropFirst().first, s.active.bands.count))
                default: throw Bad("Use: nod band list|set|add|remove")
                }
            default: throw Bad("Unknown command \"\(verb)\". Try: nod help")
            }
        }
        if verb == "band", result == 0 { return printBands() }
        return done(result)
    }

    // MARK: Helpers

    private struct Bad: Error { let message: String; init(_ m: String) { message = m } }

    private static func fail(_ message: String) -> Int32 { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); return 1 }
    private static func done(_ r: Int32?) -> Int32 { r == 0 ? printSettings() : (r ?? 1) }
    private static func settle() -> Int32 { usleep(700_000); return run(["status"]) }

    /// Loads config.json, applies the change, and saves it. Refuses to touch a file that doesn't parse.
    private static func edit(_ change: (inout Settings) throws -> Void) -> Int32? {
        var s: Settings
        switch Settings.load() {
        case .ok(let loaded): s = loaded
        case .missing: s = Settings()
        case .invalid(let why): return fail(why)
        }
        let before = s
        do { try change(&s) } catch let e as Bad { return fail(e.message) } catch { return fail("\(error)") }
        if s != before || Settings.modified() == nil { s.save() }
        return 0
    }

    private static func printSettings() -> Int32 {
        guard let s = try? String(contentsOf: Settings.file, encoding: .utf8) else { return fail("No settings file yet.") }
        print(s); return 0
    }

    private static func printBands() -> Int32 {
        guard case .ok(let s) = Settings.load() else { return 1 }
        for (i, b) in s.active.bands.enumerated() {
            let type = b.type.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            print("\(i + 1)  \(type) " + String(format: "%8.1f Hz  %+5.1f dB  Q %.2f  ", b.freq, b.gainDB, b.q) + (b.on ? "on" : "off"))
        }
        return 0
    }

    private static func onOff(_ a: String?, _ usage: String) throws -> Bool {
        switch a { case "on": return true; case "off": return false; default: throw Bad("Use: \(usage)") }
    }
    private static func num(_ v: String) throws -> Double { guard let d = Double(v), d.isFinite else { throw Bad("\"\(v)\" isn't a number") }; return d }
    private static func pairs(_ args: ArraySlice<String>) throws -> [(String, String)] {
        try args.map { a in
            let p = a.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { throw Bad("Expected key=value, got \"\(a)\"") }
            return (p[0], p[1])
        }
    }
    private static func index(_ a: String?, _ count: Int) throws -> Int {
        guard let a, let n = Int(a), (1...count).contains(n) else { throw Bad("Give a band number from 1 to \(count)") }
        return n - 1
    }
    private static func apply(_ kv: [(String, String)], to b: inout Band) throws {
        for (k, v) in kv {
            switch k {
            case "type": guard let t = BandType(rawValue: v) else { throw Bad("Unknown band type \"\(v)\". Use highPass, lowShelf, bell, highShelf or lowPass") }; b.type = t
            case "freq": b.freq = min(max(try num(v), 20), 20000)
            case "gain": b.gainDB = min(max(try num(v), -18), 18)
            case "q": b.q = min(max(try num(v), 0.2), 10)
            case "on": guard let f = Bool(v) else { throw Bad("on must be true or false") }; b.on = f
            default: throw Bad("Unknown band setting \"\(k)\"")
            }
        }
    }
}
