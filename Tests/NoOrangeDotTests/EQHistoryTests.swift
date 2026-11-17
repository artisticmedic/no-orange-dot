import XCTest
@testable import NoOrangeDot

final class EQHistoryTests: XCTestCase {
    private func curve(_ gain: Double) -> [Band] { [Band(type: .bell, freq: 1000, gainDB: gain, q: 1)] }

    func testUndoAndRedoTraverseMultipleEdits() {
        let a = curve(0), b = curve(2), c = curve(4)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.record(before: a, after: b); history.flush()
        history.record(before: b, after: c); history.flush()
        XCTAssertEqual(history.undo(current: c), b)
        XCTAssertEqual(history.undo(current: b), a)
        XCTAssertFalse(history.canUndo)
        XCTAssertNil(history.undo(current: a))
        XCTAssertEqual(history.redo(current: a), b)
        XCTAssertEqual(history.redo(current: b), c)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo(current: c))
        XCTAssertTrue(history.snapshots.contains { $0.bands == c }, "Undo keeps the replaced curve in the browsing archive")
    }

    func testUndoBeforeDebounceThenUndoAgainReachesOriginalCurve() {
        let a = curve(0), b = curve(2), c = curve(4)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.record(before: a, after: b); history.flush()
        history.record(before: b, after: c)
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo(current: c), b)
        XCTAssertFalse(history.flush(), "A delayed callback must not insert another edit after Undo")
        XCTAssertEqual(history.undo(current: b), a)
        XCTAssertFalse(history.canUndo)
    }

    func testDragIsOneUndoableEdit() {
        let a = curve(0), b = curve(2), c = curve(4)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.record(before: a, after: b)
        history.record(before: b, after: c)
        history.flush()
        XCTAssertEqual(history.undo(current: c), a)
        XCTAssertFalse(history.canUndo)
    }

    func testReturningADragToItsStartingCurveCreatesNoEdit() {
        let a = curve(0), b = curve(2)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.record(before: a, after: b)
        history.record(before: b, after: a)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.flush())
        XCTAssertTrue(history.snapshots.isEmpty)
    }

    func testNewEditAfterUndoDiscardsRedoAndKeepsEarlierUndo() {
        let a = curve(0), b = curve(2), c = curve(4), d = curve(6)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.replace(before: a, after: b)
        history.replace(before: b, after: c)
        XCTAssertEqual(history.undo(current: c), b)
        XCTAssertTrue(history.canRedo)
        history.record(before: b, after: d)
        XCTAssertFalse(history.canRedo)
        history.flush()
        XCTAssertNil(history.redo(current: d))
        XCTAssertEqual(history.undo(current: d), b)
        XCTAssertEqual(history.undo(current: b), a)
    }

    func testExternalCurveReplacementIsUndoableAndInvalidatesRedo() {
        let a = curve(0), b = curve(2), c = curve(4), external = curve(-3)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.replace(before: a, after: b)
        history.replace(before: b, after: c)
        XCTAssertEqual(history.undo(current: c), b)
        history.replace(before: b, after: external)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo(current: external), b)
        XCTAssertEqual(history.undo(current: b), a)
    }

    func testClearingCancelsPendingInsertAndTraversal() {
        let a = curve(0), b = curve(2), c = curve(4), d = curve(6)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.replace(before: a, after: b)
        history.record(before: b, after: c)
        history.clear()
        XCTAssertFalse(history.flush(), "The delayed debounce callback cannot resurrect cleared history")
        XCTAssertTrue(history.snapshots.isEmpty)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        history.record(before: c, after: d)
        history.flush()
        XCTAssertEqual(history.snapshots.count, 1)
        XCTAssertEqual(history.snapshots.first?.bands, c)
        XCTAssertEqual(history.undo(current: d), c)
        XCTAssertFalse(history.canUndo)
    }

    func testFirstEditAfterSwitchingBetweenIdenticalCurvesIsCaptured() {
        let flat = curve(0), changed = curve(2)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.selectMic("laptop", name: "Laptop mic")
        history.record(before: flat, after: changed)
        history.flush()
        XCTAssertEqual(history.snapshots.first?.bands, flat)
        XCTAssertEqual(history.snapshots.first?.micUID, "laptop")
        XCTAssertEqual(history.undo(current: changed), flat)
        history.selectMic("desk", name: "Desk mic")
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testMicSwitchCommitsOutgoingPendingEditAndKeepsSeparateStacks() {
        let a = curve(0), b = curve(2), x = curve(-2), y = curve(-4)
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.record(before: a, after: b)
        history.selectMic("laptop", name: "Laptop mic")
        XCTAssertEqual(history.snapshots.first?.micUID, "desk")
        XCTAssertEqual(history.snapshots.first?.mic, "Desk mic")
        XCTAssertEqual(history.snapshots.first?.bands, a)
        XCTAssertFalse(history.canUndo)
        history.record(before: x, after: y)
        history.flush()
        XCTAssertEqual(history.undo(current: y), x)
        history.selectMic("desk", name: "Desk mic")
        XCTAssertEqual(history.undo(current: b), a)
        XCTAssertFalse(history.canUndo)
    }

    func testSavedArchiveRemainsBrowsableWithoutInventingSessionUndoState() {
        let snapshot = EQSnapshot(date: Date(timeIntervalSince1970: 1000), mic: "Desk mic", bands: curve(0))
        var history = EQHistory(snapshots: [snapshot])
        history.selectMic("desk", name: "Desk mic")
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.snapshots, [snapshot])
    }
}

final class EQHistoryPersistenceTests: XCTestCase {
    private var home: URL!
    private var file: URL { home.appendingPathComponent("history.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nod-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    func testLegacySnapshotsStillLoadWithoutAMicrophoneID() throws {
        try Data(#"[{"date":"2026-11-16T12:00:00Z","mic":"Legacy mic","bands":[]}]"#.utf8).write(to: file)
        let archive = try EQSnapshot.read(from: file)
        XCTAssertEqual(archive.snapshots.count, 1)
        XCTAssertEqual(archive.snapshots.first?.mic, "Legacy mic")
        XCTAssertNil(archive.snapshots.first?.micUID)
    }

    func testPendingEditCanBeFlushedAndSavedImmediatelyAtQuit() throws {
        let missing = try EQSnapshot.read(from: file)
        let a = [Band(type: .bell, freq: 1000, gainDB: 0, q: 1)]
        let b = [Band(type: .bell, freq: 1000, gainDB: 3, q: 1)]
        var history = EQHistory()
        history.selectMic("desk", name: "Desk mic")
        history.record(before: a, after: b, date: Date(timeIntervalSince1970: 1000))
        history.flush()
        _ = try EQSnapshot.save(history.snapshots, expecting: missing.revision, to: file)
        let saved = try EQSnapshot.read(from: file)
        XCTAssertEqual(saved.snapshots.count, 1)
        XCTAssertEqual(saved.snapshots.first?.bands, a)
        XCTAssertEqual(saved.snapshots.first?.micUID, "desk")
    }

    func testFlushCannotOverwriteNewerHistory() throws {
        let original = try EQSnapshot.save([], expecting: nil, to: file)
        let external = Data(#"[{"date":"2026-11-16T12:00:00Z","mic":"External mic","bands":[]}]"#.utf8)
        try external.write(to: file, options: .atomic)
        XCTAssertThrowsError(try EQSnapshot.save([], expecting: original.revision, to: file)) { error in
            guard case EQSnapshot.Failure.changed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), external)
    }

    func testFlushLeavesMalformedHistoryUntouched() throws {
        let original = try EQSnapshot.save([], expecting: nil, to: file)
        let partial = Data("[ unfinished".utf8)
        try partial.write(to: file)
        XCTAssertThrowsError(try EQSnapshot.save([], expecting: original.revision, to: file)) { error in
            guard case EQSnapshot.Failure.invalid = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), partial)
    }

    func testHistoryWriteFailureIsReportedAndPreservesTheOldFile() throws {
        let original = try EQSnapshot.save([], expecting: nil, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        let snapshot = EQSnapshot(date: Date(timeIntervalSince1970: 1000), mic: "Desk mic", bands: [])
        XCTAssertThrowsError(try EQSnapshot.save([snapshot], expecting: original.revision, to: file)) { error in
            guard case EQSnapshot.Failure.write = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), original.revision)
    }
}
