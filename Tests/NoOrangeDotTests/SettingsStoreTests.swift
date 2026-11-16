import XCTest
@testable import NoOrangeDot

final class SettingsStoreTests: XCTestCase {
    private var home: URL!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nod-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = SettingsStore(file: home.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    func testMissingFileCanBeCreatedFromItsSnapshot() throws {
        let missing = try store.read()
        XCTAssertNil(missing.revision)
        var settings = missing.settings
        settings.muted = true
        let saved = try store.save(settings, expecting: missing.revision)
        XCTAssertEqual(saved.revision, try Data(contentsOf: store.file))
        XCTAssertEqual(try store.read().settings, settings)
    }

    func testPendingEditCannotOverwriteNewerBytesEvenWithTheSameModificationDate() throws {
        let saved = try store.save(Settings(), expecting: nil)
        let stamp = try FileManager.default.attributesOfItem(atPath: store.file.path)[.modificationDate]
        let external = Data(#"{"muted":true,"micName":"External edit"}"#.utf8)
        try external.write(to: store.file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(stamp)], ofItemAtPath: store.file.path)
        var pending = saved.settings
        pending.icon = "ring"
        XCTAssertThrowsError(try store.save(pending, expecting: saved.revision)) { error in
            guard case SettingsStore.Failure.changed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: store.file), external)
    }

    func testPendingEditLeavesAnInvalidHandEditUntouched() throws {
        let saved = try store.save(Settings(), expecting: nil)
        let partial = Data("{ not finished".utf8)
        try partial.write(to: store.file)
        XCTAssertThrowsError(try store.save(saved.settings, expecting: saved.revision)) { error in
            guard case SettingsStore.Failure.invalid = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: store.file), partial)
    }

    func testPendingEditDoesNotRecreateAnExternallyDeletedFile() throws {
        let saved = try store.save(Settings(), expecting: nil)
        try FileManager.default.removeItem(at: store.file)
        XCTAssertThrowsError(try store.save(saved.settings, expecting: saved.revision)) { error in
            guard case SettingsStore.Failure.changed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }

    func testUnreadableFileIsNotTreatedAsMissingOrReplaced() throws {
        let saved = try store.save(Settings(), expecting: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path) }
        XCTAssertThrowsError(try store.read()) { error in
            guard case SettingsStore.Failure.read = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try store.save(saved.settings, expecting: saved.revision))
    }

    func testAtomicWriteFailureIsReportedAndKeepsTheOldFile() throws {
        let saved = try store.save(Settings(), expecting: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        var pending = saved.settings
        pending.muted = true
        XCTAssertThrowsError(try store.save(pending, expecting: saved.revision)) { error in
            guard case SettingsStore.Failure.write = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: store.file), saved.revision)
    }

    func testEncodingFailureIsReportedWithoutReplacingTheFile() throws {
        let saved = try store.save(Settings(), expecting: nil)
        var pending = saved.settings
        pending.active.outputGainDB = .infinity
        XCTAssertThrowsError(try store.save(pending, expecting: saved.revision)) { error in
            guard case SettingsStore.Failure.write = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: store.file), saved.revision)
    }

    func testConcurrentWritersCannotBothReplaceTheSameRevision() throws {
        let saved = try store.save(Settings(), expecting: nil)
        let file = store.file
        let results = WriterResults()
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            var pending = saved.settings
            pending.micName = "Writer \(i)"
            do {
                _ = try SettingsStore(file: file).save(pending, expecting: saved.revision)
                results.recordSuccess()
            } catch { results.record(error) }
        }
        XCTAssertEqual(results.successes, 1)
        XCTAssertEqual(results.errors.count, 11)
        for error in results.errors {
            guard case SettingsStore.Failure.changed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(try store.read().settings.micName.hasPrefix("Writer "))
    }

    private final class WriterResults {
        private let lock = NSLock()
        private(set) var successes = 0
        private(set) var errors: [Error] = []

        func recordSuccess() { lock.lock(); defer { lock.unlock() }; successes += 1 }
        func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
    }
}
