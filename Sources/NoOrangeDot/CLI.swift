import Foundation

/// Command-line control, so scripts and agents can do everything the windows can.
/// Settings verbs edit config.json, which the running app re-reads within half a second.
enum CLI {
    static let verbs: Set<String> = ["status", "get", "mute", "eq", "preset", "band", "gate", "comp", "input", "output", "mics", "name", "play", "auto-eq", "recordings", "cli", "record", "system", "icon", "appicon", "dock", "gain", "listen", "limiter", "shortcut", "history", "update", "crashes", "open", "help", "--help", "-h"]

    static let help = """
    nod: control \(Brand.name)

      nod status                         what the app is doing now, as JSON
      nod get                            all settings, as JSON
      nod mute on|off|toggle
      nod eq on|off
      nod preset warm|flat               a starting curve for the EQ
      nod preset list                    saved sounds: EQ, gate, compressor, limiter and output level
      nod preset save <name>             save the current sound, or replace the preset with that name
      nod preset use <name or number>
      nod preset delete <name or number>
      nod band list
      nod band set <n> [type=bell] [freq=480] [gain=-3] [q=0.7] [on=true]
      nod band add type=bell freq=1000 [gain=0] [q=1]
      nod band remove <n>
      nod gate on|off [threshold=-50] [range=-30]
      nod comp on|off [threshold=-18] [ratio=3] [attack=8] [release=150] [makeup=0]
      nod limiter on|off [ceiling=-1]    catch peaks before they clip
      nod record start|stop|toggle
      nod shortcut list                     every command that can have a shortcut; none are set to begin with
      nod shortcut <command> <keys>|off     e.g. nod shortcut mute ctrl+opt+cmd+m
      nod crashes                        crash reports macOS has written for this app; nothing is ever sent
      nod crashes show <n>               the short summary that would go into a GitHub issue
      nod update                         look for a new version
      nod update install                 download it, check who signed it, and open the installer
      nod update auto on|off             look once a day
      nod update feed <https address>|reset
      nod auto-eq measure [seconds=20] [target=warm] [strength=1] [apply]
                                         listen to the mic, then suggest an EQ (speak the whole time)
      nod auto-eq match <reference audio> <this mic's audio> [strength=1] [apply] [out=<wav>]
                                         make this mic sound like the reference. Both should be the same words.
      nod auto-eq file <audio> [target=warm|neutral|bright] [strength=1] [apply] [out=<wav>] [curves]
                                         work out an EQ from a recording of speech
      nod input list | nod input <name>
      nod mics                           included microphones in priority order, then other known microphones
      nod mics include <name>           add a microphone to automatic selection
      nod mics exclude <name>           remove it from automatic selection, keeping its saved sound
      nod mics move <name> <place>       reorder an included microphone, counted from 1
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
        case "get": return done(edit { _ in })
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
            func name(_ uid: String) -> String { names[uid] ?? s.mics[uid].map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? uid }
            if rest.first == "include" || rest.first == "exclude" {
                let want = rest.dropFirst().joined(separator: " ").lowercased()
                guard !want.isEmpty else { return fail("Use: nod mics include|exclude <name>") }
                let known = Array(Set(s.micOrder).union(s.mics.keys).union(names.keys)).sorted()
                let exact = known.filter { name($0).lowercased() == want || $0.lowercased() == want }
                let matches = exact.isEmpty ? known.filter { name($0).lowercased().contains(want) } : exact
                guard matches.count == 1, let uid = matches.first else {
                    return fail(matches.isEmpty ? "No microphone matches that name. Try: nod mics" : "More than one microphone matches. Use its full name or device ID.")
                }
                guard edit({ settings in
                    settings.includeMic(uid, included: rest.first == "include")
                    var profile = settings.mics[uid] ?? MicProfile()
                    profile.name = name(uid)
                    settings.mics[uid] = profile
                }) == 0 else { return 1 }
                return run(["mics"])
            }
            if rest.first == "move" {
                guard rest.count >= 3, let place = Int(rest.last!), place >= 1 else { return fail("Use: nod mics move <name> <place>") }
                let want = rest[1..<(rest.count - 1)].joined(separator: " ").lowercased()
                let listed = s.micOrder
                guard let uid = listed.first(where: { name($0).lowercased() == want }) ?? listed.first(where: { name($0).lowercased().contains(want) }) else {
                    return fail("No microphone matches \"\(want)\". Try: nod mics")
                }
                guard edit({ $0.moveMic(uid, to: place) }) == 0 else { return 1 }
                return run(["mics"])
            }
            guard rest.isEmpty else { return fail("Use: nod mics, or nod mics include|exclude|move <name> [place]") }
            let other = Set(s.mics.keys).union(names.keys).filter { !$0.isEmpty && !s.micOrder.contains($0) }.sorted { name($0) < name($1) }
            for (i, uid) in (s.micOrder + other).enumerated() {
                let sound = s.mics[uid].map { p in "  (\(p.bands.filter(\.on).count) bands\(p.dynamics.gateOn ? ", gate" : "")\(p.dynamics.compOn ? ", compressor" : ""))" } ?? ""
                let rank = i < s.micOrder.count ? "\(i + 1)." : "–"
                let membership = i < s.micOrder.count ? "" : "  (not included)"
                print("\(uid == s.inputUID ? "*" : " ") \(rank) \(name(uid))\(membership)\(names[uid] == nil ? "  (not plugged in)" : "")\(sound)")
            }
            return 0
        case "system":
            guard let a = rest.first, a == "on" || a == "off" else { return fail("Use: nod system on|off") }
            Command.send("system-\(a)"); return settle()
        case "shortcut":
            if rest.isEmpty || rest == ["list"] {
                var s = Settings()
                if case .ok(let saved) = Settings.load() { s = saved }
                for c in MenuCommand.all {
                    let keys = s.shortcut(for: c.id)
                    print("\(c.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \((keys.isEmpty ? "-" : keys).padding(toLength: 18, withPad: " ", startingAt: 0)) \(c.menu): \(c.title)\(c.global ? " (any app)" : "")")
                }
                return 0
            }
            guard rest.count == 2, let command = MenuCommand.named(rest[0]) else { return fail("Use: nod shortcut <command> <keys>|off, for example nod shortcut mute ctrl+opt+cmd+m. nod shortcut list names the commands.") }
            let value = rest[1] == "off" ? "" : rest[1]
            if !value.isEmpty, Shortcut(value) == nil { return fail("Can't read \"\(value)\". Use a key with ctrl or cmd, for example ctrl+opt+cmd+m, or a function key such as f13.") }
            let text = Shortcut(value)?.text ?? ""
            if let shortcut = Shortcut(value), case .ok(let saved) = Settings.load(), let holder = saved.holder(of: shortcut, except: command.id) {
                return fail("\(shortcut.display) is already used by \(holder).")
            }
            if let shortcut = Shortcut(value), let standard = MenuCommand.reserved[shortcut.text] { return fail("\(shortcut.display) is already used by \(standard).") }
            return done(edit { $0.setShortcut(text, for: command.id) })
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
                guard rest.count > 1, let n = Int(rest[1]), n >= 1, n <= list.count else { return fail("Use: nod history restore <n>, with a number from nod history") }
                Command.send("history-restore \(n)"); return settle()
            case "clear": Command.send("history-clear"); return 0
            default: return fail("Use: nod history, nod history restore <n>, or nod history clear")
            }
        case "crashes":
            let list = CrashReport.all()
            switch rest.first {
            case nil:
                if list.isEmpty { print("No crash reports.") }
                for (i, r) in list.enumerated() { print("\(i + 1)  \(r.date.formatted(date: .abbreviated, time: .shortened))  \(r.appVersion)  \(r.exception)") }
                return 0
            case "show":
                guard rest.count > 1, let n = Int(rest[1]), n >= 1, n <= list.count else { return fail("Use: nod crashes show <n>, with a number from nod crashes") }
                print(list[n - 1].summary); print("\nFull report: \(list[n - 1].file.path)")
                return 0
            default: return fail("Use: nod crashes, or nod crashes show <n>")
            }
        case "update":
            switch rest.first {
            case "auto":
                guard rest.count == 2, rest[1] == "on" || rest[1] == "off" else { return fail("Use: nod update auto on|off") }
                return done(edit { $0.autoUpdate = rest[1] == "on" })
            case "feed":
                guard rest.count == 2 else { return fail("Use: nod update feed <https address>, or nod update feed reset") }
                if rest[1] != "reset", URL(string: rest[1]).map(UpdateCheck.allowed) != true { return fail("The update address must start with https://") }
                return done(edit { $0.updateFeed = rest[1] == "reset" ? "" : rest[1] })
            case nil, "check", "install":
                guard case .ok(let s) = Settings.load() else { return fail("No settings file yet.") }
                let feed = s.updateFeed.isEmpty ? UpdateCheck.builtInFeed : s.updateFeed
                guard !feed.isEmpty else { return fail("No update address is set yet. Set one with: nod update feed <https address>") }
                do {
                    switch try wait({ try await UpdateCheck.check(feed: feed) }) {
                    case .upToDate: print("Up to date (\(Version.current))."); return 0
                    case .needsNewerSystem(let r): print("Version \(r.version) needs macOS \(r.minimumSystem ?? "") or later."); return 0
                    case .available(let r):
                        guard rest.first == "install" else {
                            print("Version \(r.version) is available. You have \(Version.current).\(r.notes.map { "\n\($0)" } ?? "")\nInstall it with: nod update install")
                            return 0
                        }
                        let pkg = try wait { try await UpdateCheck.download(r) }
                        if let problem = UpdateCheck.problem(with: pkg, team: UpdateCheck.ownTeam) {
                            try? FileManager.default.removeItem(at: pkg)
                            return fail(problem)
                        }
                        let open = Process()
                        open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = [pkg.path]
                        try open.run(); open.waitUntilExit()
                        print("Opened the installer for version \(r.version). The app restarts by itself when it finishes.")
                        return open.terminationStatus
                    }
                } catch { return fail((error as? UpdateCheck.Problem)?.message ?? error.localizedDescription) }
            default: return fail("Use: nod update, nod update install, nod update auto on|off, or nod update feed <https address>")
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
            return done(edit { $0.selectInput(d.uid) })
        default: break
        }

        let result: Int32? = edit { s in
            switch verb {
            case "mute":
                switch rest.first { case "on": s.muted = true; case "off": s.muted = false; case "toggle": s.muted.toggle(); default: throw Bad("Use: nod mute on|off|toggle") }
            case "eq": s.active.equalizer = try onOff(rest.first, "nod eq on|off")
            case "preset":
                let key = rest.dropFirst().joined(separator: " ")
                switch rest.first {
                case "warm": s.active.bands = Presets.warm
                case "flat": s.active.bands = Presets.flat
                case "list": break
                case "save":
                    guard !key.isEmpty else { throw Bad("Use: nod preset save <name>") }
                    guard Int(key) == nil else { throw Bad("A preset's name can't be only a number, because numbers pick presets by position.") }
                    SoundPreset.save(SoundPreset(name: key, from: s.active), in: &s.presets)
                case "use":
                    guard let i = SoundPreset.index(of: key, in: s.presets) else { throw Bad("No preset matches \"\(key)\". Try: nod preset list") }
                    var p = s.active; s.presets[i].apply(to: &p); s.active = p
                case "delete":
                    guard let i = SoundPreset.index(of: key, in: s.presets) else { throw Bad("No preset matches \"\(key)\". Try: nod preset list") }
                    s.presets.remove(at: i)
                default: throw Bad("Use: nod preset list|save <name>|use <name>|delete <name>, or nod preset warm|flat")
                }
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
            try s.active.dynamics.validate()
        }
        if verb == "band", result == 0 { return printBands() }
        if verb == "preset", result == 0, ["list", "save", "delete"].contains(rest.first ?? ""), case .ok(let s) = Settings.load() {
            if s.presets.isEmpty { print("No presets yet. Save the current sound with: nod preset save <name>") }
            for (i, p) in s.presets.enumerated() { print("\(p.matches(s.active) ? "*" : " ") \(i + 1)  \(p.name)  (\(p.summary))") }
            return 0
        }
        return done(result)
    }

    // MARK: Helpers

    private struct Bad: Error { let message: String; init(_ m: String) { message = m } }

    private static func fail(_ message: String) -> Int32 { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); return 1 }
    private static func done(_ r: Int32?) -> Int32 { r == 0 ? printSettings() : (r ?? 1) }
    /// Runs async work to completion from the command line.
    private static func wait<T>(_ work: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached { do { result = .success(try await work()) } catch { result = .failure(error) }; done.signal() }
        done.wait()
        return try result.get()
    }

    private static func settle() -> Int32 { usleep(700_000); return run(["status"]) }

    /// Loads config.json, applies the change, and saves it. Refuses to touch a file that doesn't parse.
    private static func edit(_ change: (inout Settings) throws -> Void) -> Int32? {
        do {
            let snapshot = try Settings.store.read()
            var settings = snapshot.settings
            try change(&settings)
            if settings != snapshot.settings || snapshot.revision == nil {
                _ = try Settings.store.save(settings, expecting: snapshot.revision)
            }
            return 0
        } catch let error as Bad { return fail(error.message) }
        catch { return fail(error.localizedDescription) }
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
        guard count > 0 else { throw Bad("There are no bands. Add one with: nod band add freq=1000") }
        guard let a, let n = Int(a), n >= 1, n <= count else { throw Bad("Give a band number from 1 to \(count)") }
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
