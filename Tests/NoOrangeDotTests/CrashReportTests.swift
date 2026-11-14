import XCTest
@testable import NoOrangeDot

final class CrashReportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nod-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, bundleID: String, time: String, thread: Int = 1) throws {
        let head: [String: Any] = ["app_name": "NoOrangeDot", "bundleID": bundleID, "app_version": "0.1.0", "timestamp": time, "bug_type": "309"]
        let body: [String: Any] = [
            "procPath": "/Users/someone/Applications/NoOrangeDot",
            "modelCode": "Mac16,7",
            "osVersion": ["train": "macOS 27.2", "build": "26B100"],
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "faultingThread": thread,
            "threads": [
                ["frames": [["imageIndex": 1, "symbol": "mach_msg", "symbolLocation": 8]]],
                ["triggered": true, "frames": [
                    ["imageIndex": 0, "symbol": "Engine.render(_:_:)", "symbolLocation": 132],
                    ["imageIndex": 1, "imageOffset": 4096],
                ]],
            ],
            "usedImages": [["name": "NoOrangeDot", "path": "/Users/someone/Applications/NoOrangeDot"], ["name": "libsystem_kernel.dylib", "path": "/usr/lib/system/libsystem_kernel.dylib"]],
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: head), as: UTF8.self) + "\n"
            + String(decoding: try JSONSerialization.data(withJSONObject: body, options: .prettyPrinted), as: UTF8.self)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testReadsOnlyThisAppsReportsNewestFirst() throws {
        try write("NoOrangeDot-2026-11-10-101010.ips", bundleID: Brand.bundleID, time: "2026-11-10 10:10:10.00 -0700")
        try write("NoOrangeDot-2026-11-12-101010.ips", bundleID: Brand.bundleID, time: "2026-11-12 10:10:10.00 -0700")
        try write("NoOrangeDot-2026-11-13-101010.ips", bundleID: "NoOrangeDot", time: "2026-11-13 10:10:10.00 -0700") // a developer's bare binary
        try write("OtherApp-2026-11-13-101010.ips", bundleID: Brand.bundleID, time: "2026-11-13 10:10:10.00 -0700")
        try "not a report".write(to: dir.appendingPathComponent("NoOrangeDot-broken.ips"), atomically: true, encoding: .utf8)
        let list = CrashReport.all(in: dir)
        XCTAssertEqual(list.map(\.file.lastPathComponent), ["NoOrangeDot-2026-11-12-101010.ips", "NoOrangeDot-2026-11-10-101010.ips"])
    }

    func testSummaryNamesTheCrashAndLeavesOutPaths() throws {
        try write("NoOrangeDot-a.ips", bundleID: Brand.bundleID, time: "2026-11-12 10:10:10.00 -0700")
        let r = try XCTUnwrap(CrashReport.all(in: dir).first)
        XCTAssertEqual(r.exception, "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertEqual(r.frames, ["NoOrangeDot  Engine.render(_:_:) + 132", "libsystem_kernel.dylib  + 4096"])
        XCTAssertTrue(r.summary.contains("App version: 0.1.0"))
        XCTAssertTrue(r.summary.contains("macOS 27.2 (26B100)"))
        XCTAssertFalse(r.summary.contains("/Users/"), "no paths, so no user name")
        let url = try XCTUnwrap(r.issueURL)
        XCTAssertTrue(url.absoluteString.hasPrefix(CrashReport.issues + "?title=Crash"))
        XCTAssertFalse(url.absoluteString.removingPercentEncoding!.contains("/Users/"))
        XCTAssertLessThan(url.absoluteString.count, 6000)
    }

    /// Positive control: any real report macOS has written on this Mac parses into an exception and frames.
    func testParsesARealReportFromThisMac() throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: CrashReport.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ips" {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let split = text.firstIndex(of: "\n"),
                  let head = try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8)) as? [String: Any],
                  head["bug_type"] as? String == "309" else { continue }
            // Read it as if it were ours by passing whatever bundle ID it carries.
            guard let id = head["bundleID"] as? String, let r = CrashReport.read(file, bundleID: id) else { continue }
            XCTAssertNotEqual(r.exception, "Unknown", file.lastPathComponent)
            XCTAssertFalse(r.frames.isEmpty, file.lastPathComponent)
            XCTAssertGreaterThan(r.date, Date.distantPast)
            return
        }
        throw XCTSkip("no crash report with a bundle ID on this Mac")
    }
}
