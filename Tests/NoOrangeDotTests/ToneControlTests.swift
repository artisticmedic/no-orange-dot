import XCTest
@testable import NoOrangeDot

final class ToneControlTests: XCTestCase {
    private func control(_ id: String) -> ToneControl { ToneControl.all.first { $0.id == id }! }

    func testReadsTheBandsAlreadyCoveringEachRegion() {
        let bands = Presets.warm   // high-pass 50, low shelf 150 +2.9, bell 480 -3, bell 2500 0, high shelf 4000 +2.8
        XCTAssertEqual(control("rumble").value(in: bands), 50)
        XCTAssertEqual(control("weight").value(in: bands), 2.9)
        XCTAssertEqual(control("body").value(in: bands), 0, "no band covers 150-320 Hz")
        XCTAssertEqual(control("box").value(in: bands), 3, "a -3 dB cut at 480 Hz reads as 3 towards Open")
        XCTAssertEqual(control("words").value(in: bands), 0)
        XCTAssertEqual(control("edge").value(in: bands), 2.8)
    }

    func testMovingAControlEditsItsBandInPlace() throws {
        let bands = try XCTUnwrap(control("weight").setting(4.5, in: Presets.warm))
        XCTAssertEqual(bands.count, Presets.warm.count)
        XCTAssertEqual(bands[1].gainDB, 4.5)
        XCTAssertEqual(bands[1].freq, 150, "the existing band keeps its frequency")
        let open = try XCTUnwrap(control("box").setting(5, in: Presets.warm))
        XCTAssertEqual(open[2].gainDB, -5)
    }

    func testAControlWithoutABandAddsOneOnlyWhenMoved() throws {
        XCTAssertEqual(control("body").setting(0, in: Presets.warm), Presets.warm)
        let bands = try XCTUnwrap(control("body").setting(2, in: Presets.warm))
        XCTAssertEqual(bands.count, Presets.warm.count + 1)
        XCTAssertEqual(bands.last, Band(type: .bell, freq: 220, gainDB: 2, q: 0.8))
        XCTAssertEqual(control("body").value(in: bands), 2)
    }

    func testAFullEQRefusesANewBandButStillEditsExistingOnes() {
        let full = Array(repeating: Band(type: .bell, freq: 1000, gainDB: 0, q: 1), count: DSPChain.maxBands - 1) + [Band(type: .lowShelf, freq: 120, gainDB: 0, q: 0.71)]
        XCTAssertNil(control("body").setting(2, in: full))
        XCTAssertEqual(control("weight").setting(3, in: full)?.last?.gainDB, 3)
    }

    func testRumbleTurnsTheHighPassOffAtTheBottomAndOnAgainAbove() throws {
        let off = try XCTUnwrap(control("rumble").setting(20, in: Presets.warm))
        XCTAssertFalse(off[0].on)
        XCTAssertEqual(control("rumble").value(in: off), 20)
        XCTAssertEqual(control("rumble").label(20), "Off")
        let on = try XCTUnwrap(control("rumble").setting(85, in: off))
        XCTAssertTrue(on[0].on)
        XCTAssertEqual(on[0].freq, 85)
    }

    func testANarrowNotchIsNotTreatedAsTheRegionsBand() throws {
        let notch = Band(type: .bell, freq: 218, gainDB: -18, q: 10)
        let bands = Presets.warm + [notch]
        XCTAssertEqual(control("body").value(in: bands), 0)
        let moved = try XCTUnwrap(control("body").setting(2, in: bands))
        XCTAssertEqual(moved[5], notch, "the notch keeps its settings")
        XCTAssertEqual(moved.last, Band(type: .bell, freq: 220, gainDB: 2, q: 0.8))
    }

    func testRegionsDoNotOverlapForTheSameBandType() {
        let all = ToneControl.all
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] where a.type == b.type {
                XCTAssertFalse(a.covers.overlaps(b.covers), "\(a.id) and \(b.id) would fight over one band")
            }
        }
    }
}
