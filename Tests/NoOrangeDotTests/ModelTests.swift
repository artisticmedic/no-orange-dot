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

    func testShortcutParsing() {
        XCTAssertEqual(Shortcut("ctrl+opt+cmd+m")?.text, "ctrl+opt+cmd+m")
        XCTAssertEqual(Shortcut("Command + Option + R")?.text, "opt+cmd+r")
        XCTAssertEqual(Shortcut("f13")?.text, "f13")
        XCTAssertNil(Shortcut("m"), "a bare letter would swallow typing")
        XCTAssertNil(Shortcut("shift+m"))
        XCTAssertNil(Shortcut("cmd+m+r"))
        XCTAssertNil(Shortcut("cmd+nope"))
        XCTAssertNil(Shortcut(""))
    }

    func testSnapshotSummary() {
        let s = EQSnapshot(date: Date(), mic: "Mic", bands: Presets.warm)
        XCTAssertEqual(s.summary, "5 bands · low shelf +2.9, bell -3.0, high shelf +2.8")
        XCTAssertEqual(EQSnapshot(date: Date(), mic: "Mic", bands: [Band(type: .bell, freq: 1000, gainDB: 0, q: 1)]).summary, "1 band")
    }
}
