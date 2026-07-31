import Foundation
import UniformTypeIdentifiers
import ImageIO
import PDFKit
import AVFoundation

/// Lightweight, display-ready metadata about a file (or folder), shown in the
/// file-utility result stage (`Stage.fileResult`). `gather` runs off the main thread;
/// `Facts` is `Sendable` so it can be handed back to the @MainActor view via `.task`.
enum FileFacts {

    struct Facts: Sendable, Equatable {
        var name: String
        var isDirectory: Bool
        var sizeBytes: Int64
        var kind: String            // localized type description ("ZIP archive", "PDF document")
        var dimensions: String?     // "1920 × 1080" (images)
        var pageCount: Int?         // PDF
        var duration: String?       // "2:34" (audio/video)
        var itemCount: Int?         // folder: number of direct children
        var isSizePartial: Bool     // bounded folder walk stopped before full size

        /// Human file size, e.g. "1.2 MB".
        var sizeText: String {
            (isSizePartial ? "≥ " : "") + FileFacts.byteText(sizeBytes)
        }
    }

    /// Gather facts for `url`. Safe to call off the main actor.
    @concurrent nonisolated static func gather(_ url: URL) async -> Facts {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let directory = exists && isDir.boolValue

        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?
            .localizedTypeDescription
            ?? (directory ? "Folder" : url.pathExtension.uppercased())

        var size: Int64 = 0
        var items: Int? = nil
        var sizePartial = false
        if directory {
            let (s, n, partial) = folderSizeAndCount(url)
            size = s; items = n; sizePartial = partial
        } else {
            size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }

        var dimensions: String? = nil
        var pages: Int? = nil
        var duration: String? = nil
        if !directory {
            let ext = url.pathExtension.lowercased()
            if isImageExt(ext) {
                dimensions = imageDimensions(url)
            } else if ext == "pdf" {
                pages = PDFDocument(url: url)?.pageCount
            } else if isAVExt(ext) {
                duration = await assetDuration(url)
            }
        }

        return Facts(name: url.lastPathComponent, isDirectory: directory,
                     sizeBytes: size, kind: kind, dimensions: dimensions,
                     pageCount: pages, duration: duration, itemCount: items,
                     isSizePartial: sizePartial)
    }

    // MARK: - Formatting

    nonisolated static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Output-vs-original size delta for display, e.g. "73% smaller" / "18% larger" /
    /// "same size". Returns nil when a meaningful percentage can't be formed.
    nonisolated static func deltaText(output: Int64, original: Int64) -> String? {
        guard original > 0, output > 0 else { return nil }
        if output == original { return "same size" }
        let ratio = Double(output) / Double(original)
        if output < original {
            let pct = Int(((1 - ratio) * 100).rounded())
            return pct <= 0 ? nil : "\(pct)% smaller"
        } else {
            let pct = Int(((ratio - 1) * 100).rounded())
            return pct <= 0 ? nil : "\(pct)% larger"
        }
    }

    // MARK: - Probes (all nonisolated; run off-main)

    private nonisolated static func folderSizeAndCount(_ url: URL) -> (Int64, Int, Bool) {
        let fm = FileManager.default
        var total: Int64 = 0
        var directChildren = 0
        var visited = 0
        var partial = false
        var hadTraversalError = false
        let started = Date()
        let maxEntries = 10_000
        let maxSeconds: TimeInterval = 1.0
        let root = url.standardizedFileURL
        let keys: [URLResourceKey] = [
            .fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                hadTraversalError = true
                return true
            }
        ) else {
            return (0, 0, true)
        }
        while let file = enumerator.nextObject() as? URL {
            if Task.isCancelled || visited >= maxEntries
                || Date().timeIntervalSince(started) >= maxSeconds {
                partial = true
                break
            }
            visited += 1
            if file.deletingLastPathComponent().standardizedFileURL == root {
                directChildren += 1
            }
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return (total, directChildren, partial || hadTraversalError)
    }

    private nonisolated static func imageDimensions(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(w) × \(h)"
    }

    private nonisolated static func assetDuration(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return nil }
        let secs = CMTimeGetSeconds(dur)
        guard secs.isFinite, secs >= 0 else { return nil }
        let total = Int(secs.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    private nonisolated static func isImageExt(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"].contains(ext)
    }
    private nonisolated static func isAVExt(_ ext: String) -> Bool {
        ["mp4", "mov", "m4v", "avi", "mkv", "mp3", "m4a", "wav", "aac", "aiff", "flac"].contains(ext)
    }
}
