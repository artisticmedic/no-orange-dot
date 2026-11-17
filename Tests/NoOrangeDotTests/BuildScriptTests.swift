import XCTest

final class BuildScriptTests: XCTestCase {
    private func runDriverBuild(exitCode: Int) throws -> (Int32, Bool) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("build/driver-test-\(UUID().uuidString)")
        let bin = fixture.appendingPathComponent("bin")
        let scripts = fixture.appendingPathComponent("scripts")
        for folder in [bin, scripts, fixture.appendingPathComponent("vendor/BlackHole"), fixture.appendingPathComponent("build/NoOrangeDot.driver")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let script = scripts.appendingPathComponent("build-driver.sh")
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/build-driver.sh"), to: script)
        func stub(_ name: String, _ content: String) throws {
            let file = bin.appendingPathComponent(name)
            try ("#!/bin/bash\n" + content).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try stub("git", "exit 1\n")
        try stub("xcodebuild", "echo 'unfiltered compiler output'\nexit \(exitCode)\n")
        try stub("codesign", "touch \"$NOD_DRIVER_SIGNED\"\necho 'Identifier=test.driver'\n")
        let signed = fixture.appendingPathComponent("signed")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "NOD_DRIVER_SIGNED": signed.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, FileManager.default.fileExists(atPath: signed.path))
    }

    func testFailedCompileNeverSignsAStaleDriver() throws {
        let (exitCode, signed) = try runDriverBuild(exitCode: 42)
        XCTAssertEqual(exitCode, 42)
        XCTAssertFalse(signed)
    }

    func testSuccessfulCompileDoesNotNeedMatchingLogLines() throws {
        let (exitCode, signed) = try runDriverBuild(exitCode: 0)
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(signed)
    }
}
