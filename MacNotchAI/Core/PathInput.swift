import Foundation

/// Cleans up a file path a user pasted or typed into a text field.
///
/// Real-world paste sources decorate paths in ways that break a naive
/// `FileManager.fileExists` check — and the failure is silent and infuriating, because the
/// text *looks* right. Handled here:
///
///   • quotes around the path — Finder's "Copy as Pathname" and most shells produce
///     `'/Users/me/My File.pdf'` or `"…"`; also curly/smart quotes from Notes, Word, chat apps
///   • `file:///Users/me/My%20File.pdf` — dragging into a browser bar, or copying a URL
///   • backslash-escaped spaces — `/Users/me/My\ File.pdf` from a Terminal drag
///   • stray whitespace, newlines, and the zero-width/invisible characters chat clients inject
///   • `~` expansion
enum PathInput {

    static func sanitize(_ raw: String) -> String {
        var s = raw

        // Invisible characters that survive a copy from chat/word processors and make an
        // otherwise identical string fail to match a real path.
        s = s.replacingOccurrences(of: "\u{200B}", with: "")   // zero-width space
             .replacingOccurrences(of: "\u{200E}", with: "")   // LTR mark
             .replacingOccurrences(of: "\u{200F}", with: "")   // RTL mark
             .replacingOccurrences(of: "\u{FEFF}", with: "")   // BOM
             .replacingOccurrences(of: "\u{00A0}", with: " ")  // non-breaking space

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip matching wrapping quotes, repeatedly — a path can arrive double-wrapped
        // (e.g. copied out of a quoted shell command inside a chat message).
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"),
            ("\u{201C}", "\u{201D}"),   // “ ”
            ("\u{2018}", "\u{2019}"),   // ‘ ’
            ("«", "»"),
        ]
        var stripped = true
        while stripped, s.count >= 2 {
            stripped = false
            for (open, close) in pairs where s.first == open && s.last == close {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
                break
            }
        }

        // file:// URL → plain path (handles percent-encoding like %20).
        if s.lowercased().hasPrefix("file://") {
            if let url = URL(string: s), url.isFileURL {
                s = url.path
            } else if let decoded = s.removingPercentEncoding {
                s = String(decoded.dropFirst("file://".count))
            }
        }

        // Terminal-style escaped characters: `My\ File` → `My File`. Only unescape when the
        // string actually looks shell-escaped, so a genuine backslash in a name survives.
        if s.contains("\\ ") || s.contains("\\(") || s.contains("\\&") {
            for ch in [" ", "(", ")", "&", "'", "\"", ";"] {
                s = s.replacingOccurrences(of: "\\" + ch, with: ch)
            }
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s as NSString).expandingTildeInPath
    }

    /// Sanitised path resolved to an existing **directory**, or nil.
    /// Falls back to the parent folder so a user can paste a file path where a folder is
    /// wanted (the producers derive the filename themselves).
    static func resolveDirectory(_ raw: String) -> URL? {
        let path = sanitize(raw)
        guard !path.isEmpty else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: parent)
        }
        return nil
    }
}
