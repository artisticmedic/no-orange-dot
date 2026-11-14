import XCTest
@testable import NoOrangeDot

final class UpdateTests: XCTestCase {
    private let system = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    private func outcome(_ json: String, current: String = "0.1.0") throws -> UpdateCheck.Outcome {
        try UpdateCheck.parse(Data(json.utf8), current: current, system: system)
    }

    func testVersionOrder() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("1.10", than: "1.9.5"))
        XCTAssertTrue(Version.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(Version.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("0.9", than: "1.0"))
        XCTAssertFalse(Version.isNewer("1.0.0-beta", than: "1.0.0"))
    }

    func testFeedOutcomes() throws {
        let newer = #"{"version":"0.2.0","url":"https://example.com/a.pkg","notes":"Fixes."}"#
        guard case .available(let r) = try outcome(newer) else { return XCTFail("expected an update") }
        XCTAssertEqual(r.notes, "Fixes.")
        XCTAssertEqual(try outcome(newer, current: "0.2.0"), .upToDate)
        XCTAssertEqual(try outcome(newer, current: "0.3.0"), .upToDate, "never offers an older version")
        guard case .needsNewerSystem = try outcome(#"{"version":"0.2.0","url":"https://example.com/a.pkg","minimumSystem":"15.0"}"#) else {
            return XCTFail("expected a system requirement")
        }
        guard case .available = try outcome(#"{"version":"0.2.0","url":"https://example.com/a.pkg","minimumSystem":"14.5"}"#) else {
            return XCTFail("the same system version is enough")
        }
    }

    func testFeedRejectsWhatItCannotTrust() {
        XCTAssertThrowsError(try outcome("<html>not found</html>"))
        XCTAssertThrowsError(try outcome(#"{"version":"0.2.0","url":"http://example.com/a.pkg"}"#), "plain http")
        XCTAssertThrowsError(try outcome(#"{"version":"0.2.0","url":"file:///tmp/a.pkg"}"#), "local file")
        XCTAssertThrowsError(try outcome(#"{"version":"../../x","url":"https://example.com/a.pkg"}"#), "the version becomes a file name")
        XCTAssertThrowsError(try outcome(#"{"version":"","url":"https://example.com/a.pkg"}"#))
    }

    func testUnsignedPackageIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nod-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("root/file"))
        let pkg = dir.appendingPathComponent("unsigned.pkg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkgbuild")
        p.arguments = ["--root", dir.appendingPathComponent("root").path, "--identifier", "test.nod", "--version", "1", "--install-location", "/tmp/nod-never", pkg.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertNil(UpdateCheck.acceptedTeam(of: pkg))
        XCTAssertNotNil(UpdateCheck.problem(with: pkg, team: "ABCDE12345"))
        XCTAssertNotNil(UpdateCheck.problem(with: pkg, team: nil))
    }

    /// Positive control for the check above, when a notarized installer has been built on this Mac.
    func testNotarizedPackageIsAcceptedOnlyForItsOwnTeam() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pkg = root.appendingPathComponent("build/No Orange Dot \(version).pkg")
        guard FileManager.default.fileExists(atPath: pkg.path), let team = UpdateCheck.acceptedTeam(of: pkg) else {
            throw XCTSkip("no notarized installer in build/")
        }
        XCTAssertEqual(team.count, 10)
        XCTAssertNil(UpdateCheck.problem(with: pkg, team: team))
        XCTAssertNotNil(UpdateCheck.problem(with: pkg, team: "ABCDE12345"), "signed by another team")
        XCTAssertNotNil(UpdateCheck.problem(with: pkg, team: nil), "an unsigned app can't vouch for anyone")
    }
}
