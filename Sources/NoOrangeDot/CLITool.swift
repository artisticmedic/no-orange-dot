import AppKit
import Foundation

/// Puts the `nod` command on the path, the way editors install their shell commands: a link in
/// /usr/local/bin that points at this app's own binary. macOS asks for an administrator password
/// when that folder isn't writable.
enum CLITool {
    static let link = "/usr/local/bin/nod"
    static var target: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    enum State: Equatable { case notInstalled, installed, pointsElsewhere(String) }

    static var state: State {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return FileManager.default.fileExists(atPath: link) ? .pointsElsewhere(link) : .notInstalled
        }
        return dest == target ? .installed : .pointsElsewhere(dest)
    }

    /// Returns nil on success, or a sentence saying what went wrong.
    static func install() -> String? {
        run("mkdir -p /usr/local/bin && ln -sfn \(quoted(target)) \(link)", needsAdmin: !writable())
    }

    static func remove() -> String? {
        run("rm -f \(link)", needsAdmin: !writable())
    }

    /// Runs `nod status` the way a new terminal window would, so the result says whether the
    /// person's own shell can find the command, not just whether the link exists.
    static func test() -> (ok: Bool, message: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v nod && nod status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (false, "Couldn't start \(shell) to test the command.") }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (false, "The test timed out. Your shell took more than 8 seconds to start.") }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let found = text.split(separator: "\n").first.map(String.init) ?? ""
        if found.isEmpty {
            return (false, state == .installed ? "Installed, but your shell can't find it. Add /usr/local/bin to your PATH." : "Your shell can't find nod. Install it first.")
        }
        if p.terminationStatus != 0 { return (false, "Your shell found \(found), but it didn't answer. Open the app and try again.") }
        return (true, "Works. Your shell runs \(found), and it answered.")
    }

    private static func writable() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/usr/local/bin") ? fm.isWritableFile(atPath: "/usr/local/bin") : fm.isWritableFile(atPath: "/usr/local")
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func run(_ command: String, needsAdmin: Bool) -> String? {
        if !needsAdmin {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            let err = Pipe(); p.standardError = err
            do { try p.run() } catch { return "Couldn't run the installer: \(error.localizedDescription)" }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            return String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The installer failed."
        }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var info: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&info)
        guard let info else { return nil }
        if (info[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled. Nothing was changed." }
        return (info[NSAppleScript.errorMessage] as? String) ?? "macOS wouldn't make the change."
    }
}

import SwiftUI

/// The editor's card for the command-line tool: install it, test it from a real shell, remove it.
struct CLIToolView: View {
    @State private var state = CLITool.state
    @State private var message: String?
    @State private var ok = true
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        Card {
            Row(title: "Command-line tool", caption: caption) {
                HStack(spacing: 8) {
                    if state == .installed {
                        Button("Test") { test() }.buttonStyle(PillButtonStyle()).disabled(busy)
                        Button("Remove") { act(CLITool.remove) }.buttonStyle(PillButtonStyle()).disabled(busy)
                    } else {
                        Button(state == .notInstalled ? "Install" : "Replace") { act(CLITool.install) }.buttonStyle(PillButtonStyle(prominent: true)).disabled(busy)
                    }
                }
            }
            RowDivider()
            HStack(spacing: 10) {
                Image(systemName: state == .installed ? "checkmark.circle.fill" : state == .notInstalled ? "circle.dashed" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15)).foregroundStyle(state == .installed ? Color.green : state == .notInstalled ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state == .installed ? "Installed" : state == .notInstalled ? "Not installed" : "Points at another copy").font(.system(size: 14, weight: .medium))
                    Text(CLITool.link).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(CLITool.link, forType: .string); copied = true
                         DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false } } label: {
                    Label(copied ? "Copied" : "Copy Path", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .accessibilityElement(children: .contain)
            if let message {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Color.green : Color.orange)
                    Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13)).padding(.horizontal, 14).padding(.bottom, 12)
                .accessibilityElement(children: .combine)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cliToolChanged)) { _ in state = CLITool.state }
    }

    private var caption: String {
        switch state {
        case .notInstalled: return "Adds the nod command, so scripts and agents can run the app. macOS asks for your password."
        case .installed: return "Scripts and agents can run the app with nod. Try nod help in a terminal."
        case .pointsElsewhere(let where_): return "The link points at \(where_), not this copy of the app."
        }
    }

    private func act(_ change: @escaping () -> String?) {
        busy = true
        let problem = change()
        state = CLITool.state
        ok = problem == nil
        message = problem
        busy = false
        if problem == nil, state == .installed { test() }
    }

    private func test() {
        busy = true
        message = "Testing from your shell…"; ok = true
        DispatchQueue.global().async {
            let r = CLITool.test()
            DispatchQueue.main.async { ok = r.ok; message = r.message; busy = false }
        }
    }
}
