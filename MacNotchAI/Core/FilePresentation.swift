import AppKit
import Darwin

/// Presentation-only metadata and icon overrides for files shown inside Dragaway's
/// chips-stage pills. The real file extension, UTI, contents, Finder icon, and default
/// application are never changed.
@MainActor
enum FilePresentation {
    private static let originAttribute = "com.wallbrecher.dragaway.source"
    private static let webOrigin = Array("web".utf8)

    /// Mark a TXT created from an HTTP(S) payload. A private extended attribute keeps
    /// this distinction attached to the file without changing its name or contents.
    /// Failure is intentionally harmless: the pill simply falls back to the TXT icon.
    @discardableResult
    static func markAsWebDrop(_ url: URL) -> Bool {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return originAttribute.withCString { name in
                webOrigin.withUnsafeBytes { value in
                    setxattr(path, name, value.baseAddress, value.count, 0, 0)
                }
            }
        }
        return result == 0
    }

    /// A contextual icon for the pill only. Nil means the normal Workspace / Quick
    /// Look icon pipeline should remain authoritative.
    static func contextualIcon(for url: URL) -> NSImage? {
        switch url.pathExtension.lowercased() {
        case "eml", "emlx":
            return applicationIcon(
                bundleIdentifier: "com.apple.mail",
                fallbackSymbol: "envelope.fill"
            )
        case "txt" where isWebDrop(url):
            return applicationIcon(
                bundleIdentifier: "com.apple.Safari",
                fallbackSymbol: "safari"
            )
        default:
            return nil
        }
    }

    /// Immediate contextual-or-native icon used by icon-only multi-file pills.
    static func icon(for url: URL) -> NSImage {
        contextualIcon(for: url) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Concise, presentation-only type name shown above the file pill. Web-created
    /// TXT files keep their Safari identity while ordinary TXT files remain TXT.
    static func typeLabel(for url: URL) -> String {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return "Folder"
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt" where isWebDrop(url):
            return "Safari Tab"
        case "eml", "emlx":
            return "Mail"
        case "pdf":
            return "PDF"
        case "txt":
            return "TXT"
        case "md", "markdown":
            return "Markdown"
        case "jpg", "jpeg":
            return "JPEG"
        case "doc", "docx":
            return "Word"
        case "xls", "xlsx":
            return "Excel"
        case "ppt", "pptx":
            return "PowerPoint"
        case "swift":
            return "Swift"
        case "py":
            return "Python"
        case "js", "jsx":
            return "JavaScript"
        case "ts", "tsx":
            return "TypeScript"
        case "yml", "yaml":
            return "YAML"
        case "heic", "png", "gif", "tiff", "csv", "json", "xml", "html", "css", "rtf",
             "zip", "mov", "mp4", "mp3", "wav", "m4a":
            return ext.uppercased()
        case "":
            return "File"
        default:
            return ext.uppercased()
        }
    }

    private static func isWebDrop(_ url: URL) -> Bool {
        var value = [UInt8](repeating: 0, count: 32)
        let count: Int = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return originAttribute.withCString { name in
                value.withUnsafeMutableBytes { buffer in
                    getxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
                }
            }
        }
        guard count == webOrigin.count else { return false }
        return value.prefix(count).elementsEqual(webOrigin)
    }

    private static func applicationIcon(
        bundleIdentifier: String,
        fallbackSymbol: String
    ) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
    }
}
