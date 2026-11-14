import AppKit
import Foundation
import SwiftUI

/// A crash report macOS wrote for this app. Nothing is sent anywhere: the app only reads the file and,
/// if asked, opens a GitHub issue page with a short summary filled in for the person to read and post.
struct CrashReport: Identifiable, Equatable {
    let file: URL
    let date: Date
    let appVersion: String
    let system: String
    let model: String
    /// "EXC_BAD_ACCESS (SIGSEGV)"
    let exception: String
    /// The crashed thread, innermost call first: "NoOrangeDot  Engine.render(_:_:) + 132"
    let frames: [String]
    var id: URL { file }

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    static let issues = "https://github.com/artisticmedic/no-orange-dot/issues/new"

    /// Reads a .ips file: one line of JSON about the app, then a JSON body. Nil if it isn't this app's.
    static func read(_ file: URL, bundleID: String = Brand.bundleID) -> CrashReport? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), let split = text.firstIndex(of: "\n"),
              let head = try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(text[split...].utf8)) as? [String: Any],
              head["bundleID"] as? String == bundleID else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        let date = (head["timestamp"] as? String).flatMap(f.date)
            ?? ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        let ex = body["exception"] as? [String: Any] ?? [:]
        let exception = [ex["type"] as? String, (ex["signal"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        let frames = (crashed?["frames"] as? [[String: Any]] ?? []).prefix(14).map { frame -> String in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            if let symbol = frame["symbol"] as? String { return "\(image)  \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)" }
            return "\(image)  + \(frame["imageOffset"] as? Int ?? 0)"
        }
        let os = body["osVersion"] as? [String: Any] ?? [:]
        return CrashReport(file: file, date: date, appVersion: head["app_version"] as? String ?? "",
                           system: [os["train"] as? String, (os["build"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " "),
                           model: body["modelCode"] as? String ?? "", exception: exception.isEmpty ? "Unknown" : exception, frames: Array(frames))
    }

    /// This app's reports, newest first.
    static func all(in folder: URL = folder, bundleID: String = Brand.bundleID) -> [CrashReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("NoOrangeDot") }
            .compactMap { read($0, bundleID: bundleID) }.sorted { $0.date > $1.date }
    }

    /// What goes into the issue. Versions, the kind of crash and the names of the functions on the crashed
    /// thread. No file paths, no device names, no user name.
    var summary: String {
        """
        App version: \(appVersion.isEmpty ? "unknown" : appVersion)
        macOS: \(system)
        Mac: \(model)
        Crash: \(exception)

        Crashed thread:
        \(frames.isEmpty ? "(no frames)" : frames.joined(separator: "\n"))
        """
    }

    var issueURL: URL? {
        var c = URLComponents(string: Self.issues)
        c?.queryItems = [
            URLQueryItem(name: "title", value: "Crash: \(exception)"),
            URLQueryItem(name: "body", value: "**What I was doing when it quit:**\n\n\n```\n\(summary)\n```\n"),
        ]
        return c?.url
    }
}

/// Remembers which crash the person has already been told about.
@MainActor
final class CrashNotice: ObservableObject {
    static let shared = CrashNotice()
    private static let key = "crashAcknowledged"
    @Published private(set) var report: CrashReport?

    private init() { refresh() }

    func refresh() {
        let seen = UserDefaults.standard.object(forKey: Self.key) as? Date ?? .distantPast
        // Older than two weeks is no longer "last time".
        report = CrashReport.all().first { $0.date > seen && $0.date > Date().addingTimeInterval(-14 * 86400) }
    }

    func dismiss() {
        if let report { UserDefaults.standard.set(report.date, forKey: Self.key) }
        report = nil
    }
}

struct CrashBanner: View {
    @ObservedObject private var notice = CrashNotice.shared

    var body: some View {
        if let r = notice.report {
            Card {
                Row(title: "\(Brand.short) quit unexpectedly \(Recording.friendly(r.date).lowercased())",
                    caption: "\(r.exception). Nothing has been sent. Report on GitHub opens a draft you can edit before posting.") {
                    HStack(spacing: 8) {
                        Button("Show Report") { NSWorkspace.shared.activateFileViewerSelecting([r.file]) }.buttonStyle(PillButtonStyle())
                        Button("Report on GitHub…") { if let url = r.issueURL { NSWorkspace.shared.open(url) }; notice.dismiss() }.buttonStyle(PillButtonStyle())
                        IconButton(symbol: "xmark", label: "Dismiss") { notice.dismiss() }
                    }
                }
            }
        }
    }
}
