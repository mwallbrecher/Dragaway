import AppKit
import SwiftUI

/// Runs a user `Script` against the dropped file's project. Non-sandboxed app → it may spawn a
/// login shell / drive Terminal. Two modes: open in Terminal.app (live, interactive) or run in the
/// background and show captured output. The user authors every command; nothing runs without an
/// explicit tap.
enum ScriptRunner {

    @MainActor
    static func run(_ script: Script, fileURL: URL) {
        let fileDir = fileURL.deletingLastPathComponent()
        let cwd = (script.useGitRoot ? gitRoot(from: fileDir) : nil) ?? fileDir
        let command = expand(script.command, file: fileURL, fileDir: fileDir, cwd: cwd)
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if script.inTerminal {
            runInTerminal(command, cwd: cwd)
        } else {
            runCaptured(command, cwd: cwd, title: script.name)
        }
        // Tuck the overlay to its pill so the launched work has the stage (mirrors app launch).
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                OverlayViewModel.shared.isChipsExpanded = false
            }
        }
    }

    // MARK: - Placeholders + cwd

    static func expand(_ raw: String, file: URL, fileDir: URL, cwd: URL) -> String {
        let root = gitRoot(from: fileDir) ?? fileDir
        // Shell-quote every substituted value. Without this a perfectly ordinary
        // filename with a space ("My Report.pdf") breaks the command, and a crafted
        // name (`foo; rm -rf ~`) would inject into the user's shell.
        return raw
            .replacingOccurrences(of: "{file}", with: shellQuoted(file.path))
            .replacingOccurrences(of: "{dir}",  with: shellQuoted(fileDir.path))
            .replacingOccurrences(of: "{name}", with: shellQuoted(file.lastPathComponent))
            .replacingOccurrences(of: "{root}", with: shellQuoted(root.path))
    }

    /// Nearest ancestor directory containing `.git` (a repo working tree). `nil` if none.
    static func gitRoot(from dir: URL) -> URL? {
        var d = dir.standardizedFileURL
        let fm = FileManager.default
        while d.path != "/" && !d.path.isEmpty {
            if fm.fileExists(atPath: d.appendingPathComponent(".git").path) { return d }
            d = d.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Terminal.app

    private static func runInTerminal(_ command: String, cwd: URL) {
        let shell = "cd \(shellQuoted(cwd.path)) && \(command)"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleStringLiteral(shell))
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch {
            presentError("Could not open Terminal: \(error.localizedDescription)")
        }
    }

    // MARK: - Background capture

    private static func runCaptured(_ command: String, cwd: URL, title: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]            // login shell → PATH / nvm / asdf
            p.currentDirectoryURL = cwd
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                DispatchQueue.main.async { presentResult(title, "Failed to run:\n\(error.localizedDescription)") }
                return
            }
            // Drain before waiting so a large output can't deadlock the pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var out = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { out = "(no output)" }
            out += "\n\n— exit code \(p.terminationStatus)"
            DispatchQueue.main.async { presentResult(title, out) }
        }
    }

    // MARK: - Result / error panels

    @MainActor
    private static func presentResult(_ title: String, _ output: String) {
        let alert = NSAlert()
        alert.messageText = title
        // Cap so a runaway command can't make a giant alert.
        alert.informativeText = output.count > 6000 ? String(output.prefix(6000)) + "\n…(truncated)" : output
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
    }

    @MainActor
    private static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Script"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Escaping

    /// Single-quote a path for the shell (handles embedded single quotes).
    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript double-quoted string literal.
    private static func appleStringLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
