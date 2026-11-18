import XCTest

/// Runs the built binary against a throwaway settings folder. Only verbs that edit config.json are used here;
/// verbs that message the running app would reach the real one.
final class CLITests: XCTestCase {
    private var home: URL!
    private var config: URL { home.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nod-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult
    private func nod(_ args: String..., file: StaticString = #filePath, line: UInt = #line) throws -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("NoOrangeDot")
        p.arguments = args
        p.environment = ["NOD_HOME": home.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    private func settings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }

    /// The active mic's profile, wherever config.json keeps it.
    private func find(_ key: String, in value: Any) -> Any? {
        if let d = value as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values { if let hit = find(key, in: v) { return hit } }
        }
        return nil
    }

    func testGetOnAFreshFolderPrintsDefaults() throws {
        let r = try nod("get")
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(r.out.utf8)))
    }

    func testMuteRoundTrip() throws {
        XCTAssertEqual(try nod("mute", "on").code, 0)
        XCTAssertEqual(try settings()["muted"] as? Bool, true)
        XCTAssertEqual(try nod("mute", "toggle").code, 0)
        XCTAssertEqual(try settings()["muted"] as? Bool, false)
        XCTAssertEqual(try nod("mute", "sideways").code, 1)
    }

    func testBandEditing() throws {
        XCTAssertEqual(try nod("preset", "warm").code, 0)
        XCTAssertEqual(try nod("band", "add", "type=bell", "freq=2000", "gain=3").code, 0)
        var bands = try XCTUnwrap(find("bands", in: try settings()) as? [[String: Any]])
        XCTAssertEqual(bands.count, 6)
        XCTAssertEqual(bands.last?["freq"] as? Double, 2000)
        XCTAssertEqual(try nod("band", "set", "6", "gain=-4.5").code, 0)
        bands = try XCTUnwrap(find("bands", in: try settings()) as? [[String: Any]])
        XCTAssertEqual(bands.last?["gainDB"] as? Double, -4.5)
        XCTAssertEqual(try nod("band", "remove", "6").code, 0)
        let before = try Data(contentsOf: config)
        XCTAssertEqual(try nod("band", "remove", "99").code, 1)
        XCTAssertEqual(try nod("band", "set", "1", "freq=loud").code, 1)
        XCTAssertEqual(try nod("band", "set", "1", "gain=nan").code, 1)
        XCTAssertEqual(try Data(contentsOf: config), before, "a rejected edit must not rewrite the file")
    }

    func testBandLimit() throws {
        try nod("preset", "flat")
        for _ in 0..<3 { XCTAssertEqual(try nod("band", "add", "freq=900").code, 0) }
        XCTAssertEqual(try nod("band", "add", "freq=900").code, 1)
    }

    func testDynamics() throws {
        XCTAssertEqual(try nod("comp", "on", "ratio=4", "threshold=-20").code, 0)
        XCTAssertEqual(try nod("gate", "on", "hold=200").code, 0)
        XCTAssertEqual(try nod("limiter", "on", "ceiling=3").code, 0)
        XCTAssertEqual(try nod("deess", "on", "amount=8", "freq=6500").code, 0)
        let dyn = try XCTUnwrap(find("dynamics", in: try settings()) as? [String: Any])
        XCTAssertEqual(dyn["compRatio"] as? Double, 4)
        XCTAssertEqual(dyn["gateHoldMs"] as? Double, 200)
        XCTAssertEqual(dyn["limiterCeilingDB"] as? Double, 0, "a ceiling above 0 dB would clip")
        XCTAssertEqual(dyn["deessOn"] as? Bool, true)
        XCTAssertEqual(dyn["deessAmountDB"] as? Double, 8)
        XCTAssertEqual(dyn["deessFreq"] as? Double, 6500)
        XCTAssertEqual(try nod("deess", "on", "speed=4").code, 1)
        try nod("preset", "warm")
        XCTAssertEqual(try nod("tone", "weight", "4").code, 0)
        XCTAssertEqual(try nod("tone", "body", "2").code, 0)
        let bands = try XCTUnwrap(find("bands", in: try settings()) as? [[String: Any]])
        XCTAssertEqual(bands[1]["gainDB"] as? Double, 4)
        XCTAssertEqual(bands.last?["freq"] as? Double, 220)
        XCTAssertEqual(try nod("tone", "weight", "40").code, 1)
        XCTAssertEqual(try nod("tone", "loudness", "2").code, 1)
        XCTAssertTrue(try nod("tone").out.contains("Lighter to Deeper"))
        XCTAssertEqual(try nod("comp", "on", "speed=4").code, 1)
    }

    func testInvalidDynamicsAreRejectedWithoutChangingSettings() throws {
        XCTAssertEqual(try nod("gate", "on", "hold=0").code, 0)
        let before = try Data(contentsOf: config)
        for option in ["hold=1e308", "hold=-1", "release=-1", "range=30", "threshold=1e308"] {
            let result = try nod("gate", "on", option)
            XCTAssertEqual(result.code, 1, option)
            XCTAssertFalse(result.err.isEmpty)
        }
        for option in ["ratio=0", "attack=-1", "release=1e308", "makeup=1e308"] {
            XCTAssertEqual(try nod("comp", "on", option).code, 1, option)
        }
        XCTAssertEqual(try nod("limiter", "on", "ceiling=-1e308").code, 1)
        for option in ["amount=-1", "amount=1e308", "freq=20", "freq=1e308"] {
            XCTAssertEqual(try nod("deess", "on", option).code, 1, option)
        }
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testExtremeHistoryAndCrashIndicesAreRejectedBeforeSendingCommands() throws {
        XCTAssertEqual(try nod("history", "restore", String(Int.min)).code, 1)
        XCTAssertEqual(try nod("crashes", "show", String(Int.min)).code, 1)
    }

    func testEmptyBandListRejectsIndicesWithoutCrashing() throws {
        try Data(#"{"inputUID":"mic","mics":{"mic":{"bands":[]}}}"#.utf8).write(to: config)
        let before = try Data(contentsOf: config)
        XCTAssertEqual(try nod("band", "remove", "1").code, 1)
        XCTAssertEqual(try nod("band", "set", "1", "gain=1").code, 1)
        XCTAssertEqual(try Data(contentsOf: config), before)
        XCTAssertEqual(try nod("band", "add", "freq=1000").code, 0)
    }

    func testNumericPresetNamesWinOverPositionsAndExtremeIndicesAreSafe() throws {
        try Data(#"{"presets":[{"name":"2"},{"name":"Voice"}]}"#.utf8).write(to: config)
        XCTAssertEqual(try nod("preset", "delete", String(Int.min)).code, 1)
        XCTAssertEqual(try nod("preset", "delete", "2").code, 0)
        let presets = try XCTUnwrap(try settings()["presets"] as? [[String: Any]])
        XCTAssertEqual(presets.compactMap { $0["name"] as? String }, ["Voice"])
    }

    func testOversizedDynamicsInConfigAreLeftUntouched() throws {
        let invalid = Data(#"{"inputUID":"mic","mics":{"mic":{"dynamics":{"gateHoldMs":1e308}}}}"#.utf8)
        try invalid.write(to: config)
        XCTAssertEqual(try nod("mute", "on").code, 1)
        XCTAssertEqual(try Data(contentsOf: config), invalid)
    }

    func testShortcuts() throws {
        XCTAssertEqual(try nod("shortcut", "mute", "Cmd+Opt+K").code, 0)
        XCTAssertEqual(try settings()["muteShortcut"] as? String, "opt+cmd+k")
        XCTAssertEqual(try nod("shortcut", "mute", "off").code, 0)
        XCTAssertEqual(try settings()["muteShortcut"] as? String, "")
        XCTAssertEqual(try nod("shortcut", "mute", "k").code, 1)
        XCTAssertEqual(try nod("shortcut", "gate", "ctrl+opt+g").code, 0)
        XCTAssertEqual((try settings()["shortcuts"] as? [String: String])?["gate"], "ctrl+opt+g")
        XCTAssertEqual(try nod("shortcut", "gate", "off").code, 0)
        XCTAssertEqual((try settings()["shortcuts"] as? [String: String])?["gate"], nil)
        XCTAssertEqual(try nod("shortcut", "nonsense", "ctrl+opt+g").code, 1)
        XCTAssertEqual(try nod("shortcut", "gate", "cmd+q").code, 1, "Quit keeps its keys")
        XCTAssertEqual(try nod("shortcut", "gate", "ctrl+opt+g").code, 0)
        XCTAssertEqual(try nod("shortcut", "limiter", "ctrl+opt+g").code, 1, "two commands cannot share keys")
        XCTAssertEqual(try nod("shortcut", "gate", "opt+g").code, 1, "Option alone types a character")
        XCTAssertEqual(try nod("shortcut", "list").code, 0)
    }

    func testMicOrder() throws {
        let file = #"{"inputUID":"a","micOrder":["a","b"],"mics":{"a":{"name":"Desk Mic"},"b":{"name":"Laptop Mic"}}}"#
        try Data(file.utf8).write(to: config)
        XCTAssertEqual(try nod("mics", "move", "laptop", "1").code, 0)
        XCTAssertEqual(try settings()["micOrder"] as? [String], ["b", "a"])
        XCTAssertTrue(try nod("mics").out.contains("1. Laptop Mic"))
        XCTAssertEqual(try nod("mics", "move", "nonsense", "1").code, 1)
        XCTAssertEqual(try nod("mics", "move", "laptop", "0").code, 1)
    }

    func testMicPriorityMembershipAndEmptyListPersist() throws {
        try Data(#"{"inputUID":"a","micOrder":["a","b"],"mics":{"a":{"name":"Fixture Desk Mic","outputGainDB":-4},"b":{"name":"Fixture Laptop Mic"}}}"#.utf8).write(to: config)
        XCTAssertEqual(try nod("mics", "exclude", "Fixture Desk Mic").code, 0)
        XCTAssertEqual(try settings()["micOrder"] as? [String], ["b"])
        XCTAssertEqual(try nod("mics", "move", "Fixture Desk Mic", "1").code, 1)
        XCTAssertTrue(try nod("mics").out.contains("Fixture Desk Mic  (not included)"))
        XCTAssertEqual(try nod("mics", "exclude", "Fixture Laptop Mic").code, 0)
        XCTAssertEqual(try settings()["micOrder"] as? [String], [])
        XCTAssertEqual(try nod("mute", "on").code, 0)
        XCTAssertEqual(try settings()["micOrder"] as? [String], [], "reloading must not reinclude the active mic")
        XCTAssertEqual(try nod("mics", "include", "Fixture Desk Mic").code, 0)
        XCTAssertEqual(try nod("mics", "include", "Fixture Desk Mic").code, 0)
        XCTAssertEqual(try settings()["micOrder"] as? [String], ["a"])
        let mics = try XCTUnwrap(try settings()["mics"] as? [String: [String: Any]])
        XCTAssertEqual(mics["a"]?["outputGainDB"] as? Double, -4)
    }

    func testABrokenSettingsFileIsLeftAlone() throws {
        let junk = Data("{ not json".utf8)
        try junk.write(to: config)
        let r = try nod("mute", "on")
        XCTAssertEqual(r.code, 1)
        XCTAssertFalse(r.err.isEmpty)
        XCTAssertEqual(try Data(contentsOf: config), junk)
    }

    func testGetRejectsAnInvalidSettingsFile() throws {
        let junk = Data("{ not json".utf8)
        try junk.write(to: config)
        let result = try nod("get")
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.out.isEmpty)
        XCTAssertFalse(result.err.isEmpty)
        XCTAssertEqual(try Data(contentsOf: config), junk)
    }

    func testFailedSaveReturnsFailureInsteadOfPrintingOldSettings() throws {
        XCTAssertEqual(try nod("get").code, 0)
        let before = try Data(contentsOf: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        let result = try nod("mute", "on")
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.out.isEmpty)
        XCTAssertTrue(result.err.contains("Couldn't save config.json"), result.err)
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testUnreadableConfigIsNotReplacedWithDefaults() throws {
        XCTAssertEqual(try nod("get").code, 0)
        let before = try Data(contentsOf: config)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }
        let result = try nod("mute", "on")
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("Couldn't read config.json"), result.err)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testUpdateCheckAgainstALocalFeed() throws {
        let feed = home.appendingPathComponent("latest.json")
        XCTAssertEqual(try nod("update", "feed", "http://example.com/latest.json").code, 1)
        XCTAssertEqual(try nod("update", "feed", feed.absoluteString).code, 0)
        try Data(#"{"version":"99.0","url":"https://example.com/a.pkg","notes":"Better."}"#.utf8).write(to: feed)
        var r = try nod("update")
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("Version 99.0 is available"), r.out)
        XCTAssertTrue(r.out.contains("Better."))
        try Data(#"{"version":"0.0.0","url":"https://example.com/a.pkg"}"#.utf8).write(to: feed)
        r = try nod("update")
        XCTAssertTrue(r.out.contains("Up to date"), r.out)
        try Data("nonsense".utf8).write(to: feed)
        XCTAssertEqual(try nod("update").code, 1)
        XCTAssertEqual(try nod("update", "auto", "off").code, 0)
        XCTAssertEqual(try settings()["autoUpdate"] as? Bool, false)
    }

    func testPresets() throws {
        try nod("preset", "warm")
        XCTAssertEqual(try nod("preset", "save", "Warm", "radio").code, 0)
        try nod("preset", "flat"); try nod("comp", "on", "ratio=5"); try nod("output", "3")
        let saved = try nod("preset", "save", "Tight")
        XCTAssertTrue(saved.out.contains("* 2  Tight  (4 bands · compressor · +3.0 dB)"), saved.out)
        XCTAssertEqual(try nod("preset", "save", "7").code, 1)

        XCTAssertEqual(try nod("preset", "use", "1").code, 0)
        var dyn = try XCTUnwrap(find("dynamics", in: try XCTUnwrap(try settings()["mics"])) as? [String: Any])
        XCTAssertEqual(dyn["compOn"] as? Bool, false, "a preset replaces the whole sound")
        XCTAssertTrue(try nod("preset", "list").out.contains("* 1  Warm radio"))

        XCTAssertEqual(try nod("preset", "use", "tight").code, 0)
        dyn = try XCTUnwrap(find("dynamics", in: try XCTUnwrap(try settings()["mics"])) as? [String: Any])
        XCTAssertEqual(dyn["compRatio"] as? Double, 5)

        try nod("preset", "save", "tight")
        XCTAssertEqual((try settings()["presets"] as? [Any])?.count, 2, "saving under the same name replaces")
        XCTAssertEqual(try nod("preset", "use", "nope").code, 1)
        XCTAssertEqual(try nod("preset", "delete", "Warm radio").code, 0)
        XCTAssertEqual((try settings()["presets"] as? [Any])?.count, 1)
    }

    func testOutputGainRange() throws {
        XCTAssertEqual(try nod("output", "6").code, 0)
        XCTAssertEqual(try nod("output", "40").code, 1)
    }
}
