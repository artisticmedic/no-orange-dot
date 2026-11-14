import AppKit
import Foundation
import Security

/// One release, as the update feed describes it. The feed is a small JSON file at an https address:
/// { "version": "0.2.0", "url": "https://…/No Orange Dot 0.2.0.pkg", "notes": "…", "minimumSystem": "14.0" }
struct Release: Codable, Equatable {
    var version: String
    var url: String
    var notes: String?
    var minimumSystem: String?
}

enum Version {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// "1.10.0" is newer than "1.9". Anything after a hyphen is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func parts(_ v: String) -> [Int] {
        (v.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum UpdateCheck {
    enum Outcome: Equatable { case upToDate, available(Release), needsNewerSystem(Release) }

    struct Problem: Error, Equatable { let message: String; init(_ m: String) { message = m } }

    /// The built-in feed address. config.json can name another.
    static let builtInFeed = "https://updates.timgailey.com/no-orange-dot/latest.json"

    static func parse(_ data: Data, current: String = Version.current,
                      system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> Outcome {
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else { throw Problem("The update address didn't return a release.") }
        guard !Version.parts(r.version).isEmpty, r.version.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw Problem("The update address returned a version that can't be read.")
        }
        guard let url = URL(string: r.url), allowed(url) else { throw Problem("The update's download link isn't an https address.") }
        guard Version.isNewer(r.version, than: current) else { return .upToDate }
        if let need = r.minimumSystem, Version.isNewer(need, than: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)") {
            return .needsNewerSystem(r)
        }
        return .available(r)
    }

    /// https only. Tests point NOD_HOME at a throwaway folder, and only then may a feed be a local file.
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" || (url.isFileURL && ProcessInfo.processInfo.environment["NOD_HOME"] != nil)
    }

    static func check(feed: String) async throws -> Outcome {
        guard let url = URL(string: feed), allowed(url) else { throw Problem("The update address isn't an https address.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Problem("The update address answered with error \(http.statusCode).") }
            data = d
        } catch let p as Problem { throw p } catch { throw Problem("Couldn't reach the update address. \(error.localizedDescription)") }
        return try parse(data)
    }

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NoOrangeDot/Updates")
    }

    static func download(_ release: Release) async throws -> URL {
        guard let url = URL(string: release.url), allowed(url) else { throw Problem("The update's download link isn't an https address.") }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Problem("The download answered with error \(http.statusCode).") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pkg = folder.appendingPathComponent("\(Brand.short) \(release.version).pkg")
            try? FileManager.default.removeItem(at: pkg)
            try FileManager.default.moveItem(at: temp, to: pkg)
            return pkg
        } catch let p as Problem { throw p } catch { throw Problem("Couldn't download the update. \(error.localizedDescription)") }
    }

    /// The Developer ID team that signed this copy of the app. Nil for a build that isn't signed with one.
    static var ownTeam: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var fixed: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &fixed) == errSecSuccess, let fixed else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(fixed, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The team named by Gatekeeper for a package it accepts: signed with a Developer ID and notarized. Nil if it refuses.
    static func acceptedTeam(of pkg: URL) -> String? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        p.arguments = ["-a", "-vv", "-t", "install", pkg.path]
        p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let origin = text.split(separator: "\n").first(where: { $0.hasPrefix("origin=Developer ID Installer:") }),
              origin.hasSuffix(")"), let open = origin.lastIndex(of: "(") else { return nil }
        return String(origin[origin.index(after: open)..<origin.index(before: origin.endIndex)])
    }

    /// Nil when the package is safe to open: Gatekeeper accepts it and the same team that signed this app signed it.
    static func problem(with pkg: URL, team: String?) -> String? {
        guard let team, !team.isEmpty else { return "This copy of the app isn't signed, so it can't tell who made the update." }
        guard let signer = acceptedTeam(of: pkg) else { return "The download isn't a signed and notarized installer, so it wasn't opened." }
        guard signer == team else { return "The download was signed by someone else, so it wasn't opened." }
        return nil
    }
}

/// Checks the feed once a day, and on request downloads the installer, checks who signed it and opens it.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, notSetUp, checking, upToDate(Date), available(Release), needsNewerSystem(Release)
        case downloading(Release), installing(Release), failed(String)
    }

    static let shared = Updater()

    @Published private(set) var state: State = .idle
    var feed = "" { didSet { if feed != oldValue { state = feed.isEmpty ? .notSetUp : .idle } } }
    var automatic = true
    private var timer: Timer?
    private var watcher: Timer?
    private static let lastCheckKey = "lastUpdateCheck"

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkIfDue() } }
        watchForNewVersion()
    }

    var available: Release? { if case .available(let r) = state { return r }; return nil }

    var busy: Bool {
        switch state { case .checking, .downloading, .installing: return true; default: return false }
    }

    var summary: String {
        switch state {
        case .idle: return "Not checked yet."
        case .notSetUp: return "No update address is set yet."
        case .checking: return "Checking…"
        case .upToDate(let when): return "Up to date. Checked \(Recording.friendly(when).lowercased())."
        case .available(let r): return "Version \(r.version) is available." + (r.notes.map { " \($0)" } ?? "")
        case .needsNewerSystem(let r): return "Version \(r.version) needs macOS \(r.minimumSystem ?? "") or later."
        case .downloading(let r): return "Downloading version \(r.version)…"
        case .installing: return "The installer is open. The app restarts when it finishes."
        case .failed(let why): return why
        }
    }

    func checkIfDue() {
        guard automatic, !feed.isEmpty, !busy else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 3600 { check() }
    }

    func check() {
        guard !busy else { return }
        guard !feed.isEmpty else { state = .notSetUp; return }
        state = .checking
        let feed = feed
        Task {
            do {
                switch try await UpdateCheck.check(feed: feed) {
                case .upToDate: state = .upToDate(Date())
                case .available(let r): state = .available(r)
                case .needsNewerSystem(let r): state = .needsNewerSystem(r)
                }
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            } catch { state = .failed((error as? UpdateCheck.Problem)?.message ?? error.localizedDescription) }
        }
    }

    func install() {
        guard let release = available else { return }
        state = .downloading(release)
        Task {
            do {
                let pkg = try await UpdateCheck.download(release)
                if let problem = UpdateCheck.problem(with: pkg, team: UpdateCheck.ownTeam) {
                    try? FileManager.default.removeItem(at: pkg)
                    state = .failed(problem); return
                }
                guard NSWorkspace.shared.open(pkg) else { state = .failed("Couldn't open the installer."); return }
                state = .installing(release)
            } catch { state = .failed((error as? UpdateCheck.Problem)?.message ?? error.localizedDescription) }
        }
    }

    /// An installer replaces the app on disk while this copy keeps running, whether this app opened it or you did.
    /// When the version on disk changes, start the new one.
    private func watchForNewVersion() {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        watcher?.invalidate()
        watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard let onDisk = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String, onDisk != Version.current else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 5; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
            try? p.run()
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}
