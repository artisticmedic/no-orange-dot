import XCTest
@testable import NoOrangeDot

final class ModelTests: XCTestCase {
    func testDynamicsFillsMissingKeysWithDefaults() throws {
        let d = try JSONDecoder().decode(Dynamics.self, from: Data(#"{"gateOn":true,"compRatio":5}"#.utf8))
        XCTAssertTrue(d.gateOn)
        XCTAssertEqual(d.compRatio, 5)
        XCTAssertEqual(d.gateHoldMs, Dynamics().gateHoldMs)
        XCTAssertEqual(d.limiterCeilingDB, -1)
        XCTAssertFalse(d.limiterOn)
        XCTAssertFalse(d.deessOn)
        XCTAssertEqual(d.deessAmountDB, 6)
        XCTAssertEqual(d.deessFreq, 5000)
    }

    func testBandFillsMissingKeysAndRoundTrips() throws {
        let b = try JSONDecoder().decode(Band.self, from: Data(#"{"type":"bell","freq":480}"#.utf8))
        XCTAssertEqual(b, Band(type: .bell, freq: 480, gainDB: 0, q: 0.71))
        let again = try JSONDecoder().decode(Band.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(again, b)
    }

    func testBandWithUnknownTypeIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(Band.self, from: Data(#"{"type":"notch","freq":480}"#.utf8)))
    }

    func testBandSelectionWalksByFrequency() {
        let low = Band(type: .bell, freq: 100, gainDB: 0, q: 1), mid = Band(type: .bell, freq: 1000, gainDB: 0, q: 1), high = Band(type: .bell, freq: 8000, gainDB: 0, q: 1)
        let bands = [mid, high, low]
        XCTAssertEqual(Band.neighbour(of: nil, in: bands, step: 1), low.id)
        XCTAssertEqual(Band.neighbour(of: nil, in: bands, step: -1), high.id)
        XCTAssertEqual(Band.neighbour(of: low.id, in: bands, step: 1), mid.id)
        XCTAssertEqual(Band.neighbour(of: high.id, in: bands, step: 1), low.id)
        XCTAssertEqual(Band.neighbour(of: low.id, in: bands, step: -1), high.id)
        XCTAssertNil(Band.neighbour(of: nil, in: [], step: 1))
    }

    func testShortcutParsing() {
        XCTAssertEqual(Shortcut("ctrl+opt+cmd+m")?.text, "ctrl+opt+cmd+m")
        XCTAssertEqual(Shortcut("Command + Option + R")?.text, "opt+cmd+r")
        XCTAssertEqual(Shortcut("f13")?.text, "f13")
        XCTAssertNil(Shortcut("m"), "a bare letter would swallow typing")
        XCTAssertNil(Shortcut("shift+m"))
        XCTAssertNil(Shortcut("cmd+m+r"))
        XCTAssertNil(Shortcut("cmd+nope"))
        XCTAssertNil(Shortcut(""))
        XCTAssertEqual(Shortcut("opt+cmd+up")?.display, "⌥⌘↑")
        XCTAssertEqual(Settings().muteShortcut, "", "the app ships with no shortcuts")
        XCTAssertEqual(Settings().recordShortcut, "")
        XCTAssertEqual(Set(MenuCommand.all.map(\.id)).count, MenuCommand.all.count, "command IDs are unique")
        XCTAssertTrue(MenuCommand.all.allSatisfy { MenuCommand.menus.contains($0.menu) })
    }

    func testSnapshotSummary() {
        let s = EQSnapshot(date: Date(), mic: "Mic", bands: Presets.warm)
        XCTAssertEqual(s.summary, "5 bands · low shelf +2.9, bell -3.0, high shelf +2.8")
        XCTAssertEqual(EQSnapshot(date: Date(), mic: "Mic", bands: [Band(type: .bell, freq: 1000, gainDB: 0, q: 1)]).summary, "1 band")
    }

    func testChoosingAMicDoesNotChangePriorityMembership() {
        var s = Settings()
        s.micOrder = ["a", "b", "c"]
        s.selectInput("other")
        XCTAssertEqual(s.inputUID, "other")
        XCTAssertEqual(s.micOrder, ["a", "b", "c"])
        s.moveMic("c", to: 2)
        XCTAssertEqual(s.micOrder, ["a", "c", "b"])
        s.moveMic("a", to: 99)
        XCTAssertEqual(s.micOrder, ["c", "b", "a"])
    }

    func testMicOrderComesFromAnOlderFile() throws {
        let standIn = try JSONDecoder().decode(Settings.self, from: Data(#"{"inputUID":"builtin","returnToUID":"xlr"}"#.utf8))
        XCTAssertEqual(standIn.micOrder, ["xlr", "builtin"], "the chosen mic outranks the one standing in for it")
        let plain = try JSONDecoder().decode(Settings.self, from: Data(#"{"inputUID":"xlr"}"#.utf8))
        XCTAssertEqual(plain.micOrder, ["xlr"])
        let kept = try JSONDecoder().decode(Settings.self, from: Data(#"{"inputUID":"b","micOrder":["a","b"]}"#.utf8))
        XCTAssertEqual(kept.micOrder, ["a", "b"])
    }

    func testKeepingTheSystemMicrophoneIsSavedAndUnsetInOlderFiles() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"inputUID":"xlr"}"#.utf8))
        XCTAssertNil(old.systemMicrophone, "an older file leaves it to what the Mac's input already is")
        var s = Settings()
        s.systemMicrophone = true
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.systemMicrophone, true)
    }

    func testSearchMatchesWordStartsAndRanksTitlesFirst() {
        let items = [
            SearchItem(id: "a", title: "Dynamics", place: "Sound", tab: .sound),
            SearchItem(id: "b", title: "Real microphone", place: "Settings", tab: .settings, keywords: ["input"]),
            SearchItem(id: "c", title: "Mic gain", place: "Settings", tab: .settings),
            SearchItem(id: "d", title: "Use as the Mac's microphone", place: "Settings", tab: .settings),
            SearchItem(id: "e", title: "De-esser", place: "Sound", tab: .sound, keywords: ["sibilance"]),
        ]
        XCTAssertEqual(SearchItem.matches("mic", in: items).map(\.id), ["c", "b", "d"])
        XCTAssertEqual(SearchItem.matches("macs mic", in: items).map(\.id), ["d"])
        XCTAssertEqual(SearchItem.matches("deess", in: items).map(\.id), ["e"])
        XCTAssertEqual(SearchItem.matches("sib", in: items).map(\.id), ["e"])
        XCTAssertEqual(SearchItem.matches("input", in: items).map(\.id), ["b"])
        XCTAssertEqual(SearchItem.matches("  ", in: items), [])
    }

    func testPlaybackWithASelectionStartsInsideIt() {
        XCTAssertEqual(Engine.startPoint(cue: 3, selection: 1.7...4.4, length: 5), 3)
        XCTAssertEqual(Engine.startPoint(cue: 0.5, selection: 1.7...4.4, length: 5), 1.7)
        XCTAssertEqual(Engine.startPoint(cue: 4.8, selection: 1.7...4.4, length: 5), 1.7)
        XCTAssertEqual(Engine.startPoint(cue: 4.4, selection: 1.7...4.4, length: 5), 1.7)
        XCTAssertEqual(Engine.startPoint(cue: 2, selection: nil, length: 5), 2)
        XCTAssertEqual(Engine.startPoint(cue: 5, selection: nil, length: 5), 0)
    }

    func testOnlyAnInputThatJustConnectedCountsAsTakingOverTheMacsInput() {
        let now = Date()
        XCTAssertTrue(Engine.tookOver("airpods", listed: ["xlr"], connectedAt: nil, now: now), "not listed yet: it is connecting")
        XCTAssertTrue(Engine.tookOver("airpods", listed: ["xlr", "airpods"], connectedAt: now.addingTimeInterval(-3), now: now))
        XCTAssertFalse(Engine.tookOver("airpods", listed: ["xlr", "airpods"], connectedAt: now.addingTimeInterval(-60), now: now), "chosen by hand later")
        XCTAssertFalse(Engine.tookOver("builtin", listed: ["xlr", "builtin"], connectedAt: nil, now: now), "there since launch")
    }

    func testDevicesMacOSMakesPerLaunchAreDroppedWhenLoading() throws {
        let json = #"{"inputUID":"xlr","micOrder":["xlr","CADefaultDeviceAggregate-9765-0"],"mics":{"xlr":{"name":"Wave"},"CADefaultDeviceAggregate-18478-1":{"name":"CADefaultDeviceAggregate-18478-1"}}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.micOrder, ["xlr"])
        XCTAssertEqual(Array(s.mics.keys), ["xlr"])
        XCTAssertTrue(HAL.isTransient("CADefaultDeviceAggregate-93862-4"))
        XCTAssertFalse(HAL.isTransient("BuiltInMicrophoneDevice"))
    }
}
