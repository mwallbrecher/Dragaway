import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

enum FileToolError: LocalizedError {
    case fileMissing(URL)
    case pdfUnreadable(URL)
    case pdfEmpty(URL)
    case imageUnreadable(URL)
    case imageWriteFailed
    case needAtLeastTwoPDFs
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let u):   return "“\(u.lastPathComponent)” no longer exists on disk."
        case .pdfUnreadable(let u): return "“\(u.lastPathComponent)” could not be read as a PDF."
        case .pdfEmpty(let u):      return "“\(u.lastPathComponent)” has no pages."
        case .imageUnreadable(let u): return "“\(u.lastPathComponent)” could not be read as an image."
        case .imageWriteFailed:     return "The image could not be written."
        case .needAtLeastTwoPDFs:   return "Stitching needs at least two PDFs in the session."
        case .writeFailed(let m):   return "Could not write the file: \(m)"
        }
    }
}

// MARK: - Engine
//
// Pure-Apple-framework file operations on the session's documents. Every function
// that creates a new file writes it NEXT TO the source with a suffix and dedupes the
// name (-1, -2, …) so nothing is ever clobbered. Rename/Move are in-place moves of
// the original; callers must remap the live session URL afterwards
// (OverlayViewModel.remapSessionURL).

enum FileTools {

    // MARK: Reveal

    /// Selects the given files in Finder (opening a window if needed).
    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Rename (in place)

    /// Renames a file within its current directory. The original extension is
    /// preserved if `newName` does not already carry one. Returns the new URL.
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileToolError.fileMissing(url) }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent(trimmed)

        // Preserve the original extension unless the user typed a new one.
        let origExt = url.pathExtension
        if !origExt.isEmpty, target.pathExtension.lowercased() != origExt.lowercased() {
            target = target.appendingPathExtension(origExt)
        }

        target = uniqueDestination(target, allowSame: url)
        guard target != url else { return url }   // unchanged
        do { try fm.moveItem(at: url, to: target) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: Move (to a folder)

    /// Moves a file into `folder`, keeping its name (deduped on collision).
    @discardableResult
    static func move(_ url: URL, to folder: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileToolError.fileMissing(url) }
        var target = folder.appendingPathComponent(url.lastPathComponent)
        target = uniqueDestination(target, allowSame: url)
        guard target != url else { return url }
        do { try fm.moveItem(at: url, to: target) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: PDF → plain text

    /// Extracts the text of every page of a PDF and writes a sibling `.txt`.
    @discardableResult
    static func exportPDFText(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw FileToolError.pdfUnreadable(url) }
        guard doc.pageCount > 0 else { throw FileToolError.pdfEmpty(url) }

        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.string, !s.isEmpty { parts.append(s) }
        }
        let text = parts.joined(separator: "\n\n")
        let target = uniqueDestination(url.deletingPathExtension().appendingPathExtension("txt"))
        do { try text.write(to: target, atomically: true, encoding: .utf8) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: Stitch PDFs

    /// Merges every PDF in `urls` (in the given order) into one new PDF written next
    /// to the first PDF. Non-PDF entries are ignored.
    @discardableResult
    static func stitchPDFs(_ urls: [URL]) throws -> URL {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard pdfs.count >= 2 else { throw FileToolError.needAtLeastTwoPDFs }

        let merged = PDFDocument()
        var index = 0
        for url in pdfs {
            guard let doc = PDFDocument(url: url) else { throw FileToolError.pdfUnreadable(url) }
            for p in 0..<doc.pageCount {
                guard let page = doc.page(at: p) else { continue }
                // Copy the page so it isn't owned by two documents at once.
                if let copy = page.copy() as? PDFPage {
                    merged.insert(copy, at: index)
                    index += 1
                }
            }
        }
        guard index > 0 else { throw FileToolError.pdfEmpty(pdfs[0]) }

        let dir = pdfs[0].deletingLastPathComponent()
        let base = pdfs[0].deletingPathExtension().lastPathComponent
        let target = uniqueDestination(dir.appendingPathComponent("\(base)-stitched.pdf"))
        guard merged.write(to: target) else {
            throw FileToolError.writeFailed("merged PDF could not be saved")
        }
        return target
    }

    // MARK: Image resize / recompress

    /// Downscales (optional) and re-encodes an image as JPEG written next to the
    /// source. `maxDimension == nil` recompresses at the original size.
    /// - quality: JPEG quality 0…1.
    @discardableResult
    static func resizeAndRecompressImage(_ url: URL,
                                         maxDimension: CGFloat?,
                                         quality: CGFloat) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FileToolError.imageUnreadable(url)
        }

        let outImage: CGImage
        if let maxDim = maxDimension {
            // Thumbnail path downsamples efficiently and applies EXIF orientation.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform:   true,
                kCGImageSourceThumbnailMaxPixelSize:          Int(maxDim)
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw FileToolError.imageUnreadable(url)
            }
            outImage = thumb
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw FileToolError.imageUnreadable(url)
            }
            outImage = full
        }

        let base = url.deletingPathExtension().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        let suffix = maxDimension.map { "-\(Int($0))" } ?? "-compressed"
        let target = uniqueDestination(dir.appendingPathComponent("\(base)\(suffix).jpg"))

        guard let dest = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw FileToolError.imageWriteFailed }

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.1, min(quality, 1.0))
        ]
        CGImageDestinationAddImage(dest, outImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FileToolError.imageWriteFailed }
        return target
    }

    // MARK: - Helpers

    /// Returns a non-colliding URL by inserting `-1`, `-2`, … before the extension.
    /// `allowSame` (e.g. the file currently being renamed) is treated as available.
    static func uniqueDestination(_ proposed: URL, allowSame: URL? = nil) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: proposed.path) || proposed == allowSame { return proposed }

        let dir  = proposed.deletingLastPathComponent()
        let ext  = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let stem = "\(base)-\(i)"
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent(stem)
                : dir.appendingPathComponent(stem).appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) || candidate == allowSame { return candidate }
            i += 1
        }
    }
}

// MARK: - Tool catalogue + type gating

/// A file-modify action offered in the pill's ••• menu. `tools(for:sessionFiles:)`
/// returns only the items valid for a given file (and session).
enum FileTool: Identifiable, Hashable {
    case reveal
    case rename
    case move
    case pdfToText
    case stitchPDFs
    case resizeImage

    var id: String { title }

    var title: String {
        switch self {
        case .reveal:      return "Show in Finder"
        case .rename:      return "Rename…"
        case .move:        return "Move to…"
        case .pdfToText:   return "Export as .txt"
        case .stitchPDFs:  return "Stitch PDFs"
        case .resizeImage: return "Resize / Compress…"
        }
    }

    var systemImage: String {
        switch self {
        case .reveal:      return "folder"
        case .rename:      return "pencil"
        case .move:        return "arrow.right.doc.on.clipboard"
        case .pdfToText:   return "doc.plaintext"
        case .stitchPDFs:  return "doc.on.doc"
        case .resizeImage: return "photo"
        }
    }

    /// Items valid for `url`, given the full session file list (for Stitch gating).
    static func tools(for url: URL, sessionFiles: [URL]) -> [FileTool] {
        var list: [FileTool] = [.reveal, .rename, .move]
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            list.append(.pdfToText)
            let pdfCount = sessionFiles.filter { $0.pathExtension.lowercased() == "pdf" }.count
            if pdfCount >= 2 { list.append(.stitchPDFs) }
        }
        if FileInspector.isImageFile(url) {
            list.append(.resizeImage)
        }
        return list
    }
}
