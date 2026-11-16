import XCTest
@testable import NoOrangeDot

final class MicrophonePriorityTests: XCTestCase {
    func testFirstConnectedIncludedMicWinsRegardlessOfDiscoveryOrder() {
        XCTAssertEqual(MicrophonePriority.select(order: ["desk", "laptop"], available: ["phone", "laptop", "desk"], previouslyAvailable: [], manual: nil), "desk")
        XCTAssertEqual(MicrophonePriority.select(order: ["desk", "laptop"], available: ["phone", "laptop"], previouslyAvailable: ["desk", "laptop"], manual: nil), "laptop")
    }

    func testOtherMicsAreFallbacksOnlyWhenNoIncludedMicIsConnected() {
        XCTAssertEqual(MicrophonePriority.select(order: ["desk"], available: ["phone", "laptop"], previouslyAvailable: ["desk"], manual: nil), "phone")
        XCTAssertEqual(MicrophonePriority.select(order: [], available: ["phone"], previouslyAvailable: [], manual: nil), "phone")
    }

    func testManualSelectionSurvivesUnrelatedDeviceChanges() {
        XCTAssertEqual(MicrophonePriority.select(order: ["desk"], available: ["desk", "laptop", "phone"], previouslyAvailable: ["desk", "laptop"], manual: "laptop"), "laptop")
        XCTAssertEqual(MicrophonePriority.select(order: ["desk", "laptop"], available: ["desk", "laptop"], previouslyAvailable: ["desk", "laptop"], manual: "laptop"), "laptop")
    }

    func testIncludedMicReconnectingResumesPriority() {
        XCTAssertEqual(MicrophonePriority.select(order: ["desk", "backup"], available: ["desk", "backup", "laptop"], previouslyAvailable: ["backup", "laptop"], manual: "laptop"), "desk")
    }

    func testManualMicDisconnectsIntoIncludedOrOtherFallback() {
        XCTAssertEqual(MicrophonePriority.select(order: ["desk"], available: ["desk", "phone"], previouslyAvailable: ["desk", "laptop"], manual: "laptop"), "desk")
        XCTAssertEqual(MicrophonePriority.select(order: ["desk"], available: ["phone"], previouslyAvailable: ["laptop"], manual: "laptop"), "phone")
    }

    func testCurrentFallbackSurvivesDiscoveryOrderChanges() {
        XCTAssertEqual(MicrophonePriority.select(order: ["desk"], available: ["phone", "laptop"], previouslyAvailable: ["laptop"], manual: nil, current: "laptop"), "laptop")
        XCTAssertEqual(MicrophonePriority.select(order: ["desk"], available: ["phone", "desk", "laptop"], previouslyAvailable: ["phone", "laptop"], manual: nil, current: "laptop"), "desk")
        XCTAssertNil(MicrophonePriority.select(order: ["desk"], available: [], previouslyAvailable: ["laptop"], manual: nil, current: "laptop"))
    }

    func testMembershipEditsPreserveOrderAndSavedSound() {
        var s = Settings()
        s.micOrder = ["desk", "laptop"]
        var profile = MicProfile()
        profile.name = "Desk mic"
        profile.outputGainDB = -4
        s.mics["desk"] = profile
        s.includeMic("desk", included: false)
        XCTAssertEqual(s.micOrder, ["laptop"])
        XCTAssertEqual(s.mics["desk"], profile)
        s.includeMic("desk", included: true)
        s.includeMic("desk", included: true)
        XCTAssertEqual(s.micOrder, ["laptop", "desk"])
        s.moveMic("phone", to: 1)
        XCTAssertEqual(s.micOrder, ["laptop", "desk"], "moving cannot include a mic")
    }

    func testExplicitlyEmptyListSurvivesReloadWithAnActiveMic() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"inputUID":"desk","micOrder":[],"mics":{"desk":{"name":"Desk mic"}}}"#.utf8))
        XCTAssertTrue(s.micOrder.isEmpty)
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(again.micOrder.isEmpty)
        XCTAssertEqual(again.mics["desk"]?.name, "Desk mic")
    }

    func testManualSelectionDoesNotIncludeAnExcludedMic() {
        var s = Settings()
        s.micOrder = ["desk"]
        s.selectInput("phone")
        XCTAssertEqual(s.inputUID, "phone")
        XCTAssertEqual(s.micOrder, ["desk"])
    }

    func testDuplicateAndEmptyIdentifiersDoNotCreateDuplicateRows() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"micOrder":["desk","","desk","laptop"]}"#.utf8))
        XCTAssertEqual(s.micOrder, ["desk", "laptop"])
    }
}
