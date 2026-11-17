import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NoOrangeDot

@MainActor
private final class MockHotkeyRegistrar: HotkeyRegistrar {
    var registered: [UInt32: Shortcut] = [:]
    var blocked: Set<String> = []
    var operations: [String] = []

    func register(_ id: UInt32, shortcut: Shortcut) -> Bool {
        operations.append("register \(id)")
        guard !blocked.contains(shortcut.text), !registered.values.contains(shortcut) else { return false }
        registered[id] = shortcut
        return true
    }

    func unregister(_ id: UInt32) {
        operations.append("unregister \(id)")
        registered[id] = nil
    }
}

final class ShortcutReliabilityTests: XCTestCase {
    @MainActor
    func testSwappingGlobalShortcutsReleasesBothBeforeRegisteringEither() async {
        let registrar = MockHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: registrar)
        var fired: [String] = []
        var failures: [[UInt32]] = []
        hotkeys.registrationFailed = { failures.append($0) }
        hotkeys.replace(with: [
            .init(id: 1, shortcut: Shortcut("ctrl+opt+m"), action: { fired.append("old mute") }),
            .init(id: 2, shortcut: Shortcut("ctrl+opt+r"), action: { fired.append("old record") }),
        ])
        registrar.operations = []
        hotkeys.replace(with: [
            .init(id: 1, shortcut: Shortcut("ctrl+opt+r"), action: { fired.append("mute") }),
            .init(id: 2, shortcut: Shortcut("ctrl+opt+m"), action: { fired.append("record") }),
        ])
        XCTAssertEqual(registrar.operations, ["unregister 1", "unregister 2", "register 1", "register 2"])
        XCTAssertEqual(registrar.registered[1], Shortcut("ctrl+opt+r"))
        XCTAssertEqual(registrar.registered[2], Shortcut("ctrl+opt+m"))
        XCTAssertTrue(failures.isEmpty)
        hotkeys.invoke(1)
        hotkeys.invoke(2)
        XCTAssertEqual(fired, ["mute", "record"])
    }

    @MainActor
    func testRegistrationFailureDoesNotDisableOtherShortcutOrInvokeFailedAction() async {
        let registrar = MockHotkeyRegistrar()
        registrar.blocked = ["ctrl+opt+m"]
        let hotkeys = Hotkeys(registrar: registrar)
        var failures: [UInt32] = []
        var fired: [UInt32] = []
        hotkeys.registrationFailed = { failures = $0 }
        hotkeys.replace(with: [
            .init(id: 1, shortcut: Shortcut("ctrl+opt+m"), action: { fired.append(1) }),
            .init(id: 2, shortcut: Shortcut("ctrl+opt+r"), action: { fired.append(2) }),
        ])
        hotkeys.invoke(1)
        hotkeys.invoke(2)
        XCTAssertEqual(failures, [1])
        XCTAssertEqual(fired, [2])
        registrar.blocked = []
        hotkeys.suspend()
        hotkeys.resume()
        hotkeys.invoke(1)
        XCTAssertEqual(fired, [2, 1])
    }

    @MainActor
    func testRemovingAndChangingBindingsDuringCaptureUsesLatestSettingsOnResume() async {
        let registrar = MockHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: registrar)
        var fired = false
        hotkeys.replace(with: [.init(id: 1, shortcut: Shortcut("ctrl+opt+m"), action: {})])
        hotkeys.suspend()
        hotkeys.replace(with: [
            .init(id: 1, shortcut: nil, action: { XCTFail("Removed shortcut fired") }),
            .init(id: 2, shortcut: Shortcut("ctrl+opt+m"), action: { fired = true }),
        ])
        XCTAssertTrue(registrar.registered.isEmpty)
        hotkeys.invoke(2)
        XCTAssertFalse(fired)
        hotkeys.resume()
        XCTAssertNil(registrar.registered[1])
        XCTAssertEqual(registrar.registered[2], Shortcut("ctrl+opt+m"))
        hotkeys.invoke(2)
        XCTAssertTrue(fired)
    }

    @MainActor
    func testCaptureTransferKeepsOneMonitorAndOnlyLatestOwnerReceivesShortcut() async {
        let registrar = MockHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: registrar)
        hotkeys.replace(with: [.init(id: 1, shortcut: Shortcut("ctrl+opt+m"), action: { XCTFail("Global shortcut fired during capture") })])
        var installed = 0, removed = 0
        let capture = ShortcutCapture(hotkeys: hotkeys, installMonitor: { _ in installed += 1; return NSObject() },
                                      removeMonitor: { _ in removed += 1 }, invalidInput: {})
        let first = UUID(), second = UUID()
        var firstValues: [String] = [], secondValues: [String] = []
        capture.start(owner: first) { firstValues.append($0) }
        capture.start(owner: second) { secondValues.append($0) }
        capture.cancel(owner: first)
        hotkeys.invoke(1)
        XCTAssertEqual(capture.owner, second)
        XCTAssertTrue(registrar.registered.isEmpty)
        XCTAssertEqual(installed, 1)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(capture.handle(keyCode: UInt16(kVK_ANSI_M), shortcut: Shortcut("ctrl+opt+m")))
        XCTAssertTrue(firstValues.isEmpty)
        XCTAssertEqual(secondValues, ["ctrl+opt+m"])
        XCTAssertNil(capture.owner)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(registrar.registered[1], Shortcut("ctrl+opt+m"))
        XCTAssertFalse(capture.handle(keyCode: UInt16(kVK_ANSI_M), shortcut: Shortcut("ctrl+opt+m")))
    }

    @MainActor
    func testEscapeCancelsCaptureAndDeleteClearsOnlyCurrentOwner() async {
        let registrar = MockHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: registrar)
        var invalid = 0
        let capture = ShortcutCapture(hotkeys: hotkeys, installMonitor: { _ in NSObject() }, removeMonitor: { _ in },
                                      invalidInput: { invalid += 1 })
        let first = UUID(), second = UUID()
        var values: [String] = []
        capture.start(owner: first) { _ in XCTFail("Cancelled capture assigned a shortcut") }
        XCTAssertTrue(capture.handle(keyCode: UInt16(kVK_ANSI_A), shortcut: nil))
        XCTAssertEqual(invalid, 1)
        XCTAssertEqual(capture.owner, first)
        XCTAssertTrue(capture.handle(keyCode: UInt16(kVK_Escape), shortcut: nil))
        XCTAssertNil(capture.owner)
        capture.start(owner: second) { values.append($0) }
        XCTAssertTrue(capture.handle(keyCode: UInt16(kVK_Delete), shortcut: nil))
        XCTAssertEqual(values, [""])
        XCTAssertNil(capture.owner)
    }

    @MainActor
    func testMonitorFailureDoesNotLeaveGlobalShortcutsSuspended() async {
        let registrar = MockHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: registrar)
        hotkeys.replace(with: [.init(id: 1, shortcut: Shortcut("ctrl+opt+m"), action: {})])
        var failed = false
        let capture = ShortcutCapture(hotkeys: hotkeys, installMonitor: { _ in nil },
                                      removeMonitor: { _ in XCTFail("There was no monitor to remove") }, invalidInput: { failed = true })
        capture.start(owner: UUID()) { _ in XCTFail("Capture never started") }
        XCTAssertTrue(failed)
        XCTAssertNil(capture.owner)
        XCTAssertEqual(registrar.registered[1], Shortcut("ctrl+opt+m"))
    }

    func testControlTextCommandsAreDeferredOnlyWhileEditing() {
        let combinations: [NSEvent.ModifierFlags] = [.control, [.control, .shift], [.control, .option]]
        for modifiers in combinations {
            XCTAssertTrue(ShortcutRouting.defersToText(modifiers: modifiers, editingText: true))
            XCTAssertFalse(ShortcutRouting.defersToText(modifiers: modifiers, editingText: false))
        }
        XCTAssertFalse(ShortcutRouting.defersToText(modifiers: [.control, .command], editingText: true))
        XCTAssertFalse(ShortcutRouting.defersToText(modifiers: .command, editingText: true))
        XCTAssertFalse(ShortcutRouting.defersToText(modifiers: [], editingText: true))
    }
}
