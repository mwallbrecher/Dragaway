import Foundation
import AppKit
import PDFKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Errors

enum FileToolError: LocalizedError {
    case fileMissing(URL)
    case pdfUnreadable(URL)
    case pdfEmpty(URL)
    case imageUnreadable(URL)
    case imageWriteFailed
    case needAtLeastTwoPDFs
    case pdfSinglePage(URL)
    case noImages
    case invalidJSON(URL)
    case notTextReadable(URL)
    case invalidBase64(URL)
    case invalidCSV(URL)
    case jsonNotTabular(URL)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let u):   return "“\(u.lastPathComponent)” no longer exists on disk."
        case .pdfUnreadable(let u): return "“\(u.lastPathComponent)” could not be read as a PDF."
        case .pdfEmpty(let u):      return "“\(u.lastPathComponent)” has no pages."
        case .imageUnreadable(let u): return "“\(u.lastPathComponent)” could not be read as an image."
        case .imageWriteFailed:     return "The image could not be written."
        case .needAtLeastTwoPDFs:   return "Stitching needs at least two PDFs in the session."
        case .pdfSinglePage(let u): return "“\(u.lastPathComponent)” has only one page — nothing to split."
        case .noImages:             return "No images in this session to combine."
        case .invalidJSON(let u):   return "“\(u.lastPathComponent)” is not valid JSON."
        case .notTextReadable(let u): return "“\(u.lastPathComponent)” could not be read as text."
        case .invalidBase64(let u): return "“\(u.lastPathComponent)” is not valid Base64."
        case .invalidCSV(let u):    return "“\(u.lastPathComponent)” could not be parsed as CSV."
        case .jsonNotTabular(let u): return "“\(u.lastPathComponent)” must be a JSON array of objects to convert to CSV."
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

    // MARK: PDF → Markdown

    /// Converts a PDF to Markdown using PDFKit's per-page `attributedString` (which carries
    /// font size + bold/italic — unlike `.string`). Font-size jumps → headings, traits →
    /// **bold** / _italic_, line prefixes → lists, blank lines → paragraph breaks. Pure and
    /// local (no network, no LLM). Tables / exotic layouts degrade to plain paragraphs; a
    /// page with no text layer (scanned) falls back to its raw `.string`. Writes a sibling `.md`.
    @discardableResult
    static func exportPDFMarkdown(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw FileToolError.pdfUnreadable(url) }
        guard doc.pageCount > 0 else { throw FileToolError.pdfEmpty(url) }

        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let attr = page.attributedString, attr.length > 0 {
                let md = markdownFromAttributed(attr)
                if !md.isEmpty { pages.append(md) }
            } else if let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                pages.append(s)   // no text layer (scanned) — plain-text fallback
            }
        }

        let body = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = uniqueDestination(url.deletingPathExtension().appendingPathExtension("md"))
        do { try (body + "\n").write(to: target, atomically: true, encoding: .utf8) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: PDF → Word (.docx)

    /// Converts a PDF to an editable Word `.docx` using PDFKit's per-page `attributedString`
    /// (text + font sizes/styles) exported via `NSAttributedString`'s built-in OfficeOpenXML
    /// writer. Pure Apple, local. **Text-only fidelity** — like Export-as-Markdown, PDFs carry
    /// no real paragraph/table/layout structure, so the result is editable text, not a layout copy.
    @discardableResult
    static func exportPDFDocx(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw FileToolError.pdfUnreadable(url) }
        guard doc.pageCount > 0 else { throw FileToolError.pdfEmpty(url) }

        let combined = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let attr = page.attributedString, attr.length > 0 {
                combined.append(attr)
            } else if let s = page.string, !s.isEmpty {
                combined.append(NSAttributedString(string: s))
            }
            if i < doc.pageCount - 1 { combined.append(NSAttributedString(string: "\n\n")) }
        }

        let target = uniqueDestination(url.deletingPathExtension().appendingPathExtension("docx"))
        do {
            let data = try combined.data(
                from: NSRange(location: 0, length: combined.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: target)
        } catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // ── Markdown conversion helpers ──────────────────────────────────────────

    private static let bulletChars: Set<Character> = ["•", "‣", "◦", "▪", "⁃", "·", "-", "–", "—", "*"]

    private static func isBullet(_ s: String) -> Bool {
        guard let first = s.first, bulletChars.contains(first) else { return false }
        let next = s.dropFirst().first
        return next == " " || next == "\t"
    }

    private static func isNumbered(_ s: String) -> Bool {
        var idx = s.startIndex
        var sawDigit = false
        while idx < s.endIndex, s[idx].isNumber { sawDigit = true; idx = s.index(after: idx) }
        guard sawDigit, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return false }
        idx = s.index(after: idx)
        return idx < s.endIndex && (s[idx] == " " || s[idx] == "\t")
    }

    /// Normalise a detected list line: numbered → "n. text", bullet → "- text".
    private static func normalizeList(_ line: String) -> String {
        if isNumbered(line) {
            var idx = line.startIndex
            while idx < line.endIndex, line[idx].isNumber { idx = line.index(after: idx) }
            let num = line[line.startIndex..<idx]
            let rest = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            return "\(num). \(rest)"
        }
        return "- " + line.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// Bold/italic for a PDF font. `symbolicTraits` is unreliable through a PDF round-trip
    /// (PDFs encode weight in the font NAME, e.g. "Times-Bold", not as a trait), so also
    /// sniff the font name and the descriptor's numeric weight.
    private static func fontEmphasis(_ font: NSFont?) -> (bold: Bool, italic: Bool) {
        guard let font else { return (false, false) }
        let traits = font.fontDescriptor.symbolicTraits
        var bold = traits.contains(.bold)
        var italic = traits.contains(.italic)
        let name = font.fontName.lowercased()
        if !bold, name.contains("bold") || name.contains("black")
            || name.contains("heavy") || name.contains("semibold") { bold = true }
        if !italic, name.contains("italic") || name.contains("oblique") { italic = true }
        if !bold,
           let t = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
           let w = t[.weight] as? CGFloat, w >= 0.4 { bold = true }
        return (bold, italic)
    }

    /// Build the inline Markdown for a line, wrapping bold/italic runs. Headings skip
    /// emphasis (they're already strong). Preserves inter-run spacing.
    private static func inlineText(_ attr: NSAttributedString, _ range: NSRange, heading: Bool) -> String {
        let ns = attr.string as NSString
        var result = ""
        attr.enumerateAttributes(in: range, options: []) { attrs, sub, _ in
            let piece = ns.substring(with: sub).replacingOccurrences(of: "\n", with: " ")
            let core = piece.trimmingCharacters(in: .whitespaces)
            if core.isEmpty { if !piece.isEmpty { result += " " }; return }
            if heading { result += piece; return }
            let (bold, italic) = fontEmphasis(attrs[.font] as? NSFont)
            let lead = String(piece.prefix(while: { $0 == " " }))
            let trail = String(piece.reversed().prefix(while: { $0 == " " }))
            var wrapped = core
            if bold && italic { wrapped = "***\(wrapped)***" }
            else if bold      { wrapped = "**\(wrapped)**" }
            else if italic    { wrapped = "_\(wrapped)_" }
            result += lead + wrapped + trail
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Convert one page's attributed string to Markdown via font-size + trait heuristics.
    private static func markdownFromAttributed(_ attr: NSAttributedString) -> String {
        let fullRange = NSRange(location: 0, length: attr.length)

        // Body font size = the most common point size (weighted by characters).
        var sizeWeight: [Int: Int] = [:]
        attr.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let size = Int((((value as? NSFont)?.pointSize) ?? 12).rounded())
            sizeWeight[size, default: 0] += range.length
        }
        let bodySize = CGFloat(sizeWeight.max { $0.value < $1.value }?.key ?? 12)

        enum Block { case heading(Int, String); case para(String); case list(String) }
        var blocks: [Block] = []
        var paraBuf: [String] = []
        func flushPara() {
            let joined = paraBuf.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.para(joined)) }
            paraBuf.removeAll()
        }

        let ns = attr.string as NSString
        ns.enumerateSubstrings(in: fullRange, options: [.byLines]) { sub, lineRange, _, _ in
            let line = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { flushPara(); return }

            // Line metrics: largest font + whether the whole line is bold.
            var maxSize: CGFloat = 0
            var allBold = true
            var sawFont = false
            attr.enumerateAttribute(.font, in: lineRange, options: []) { value, _, _ in
                guard let f = value as? NSFont else { allBold = false; return }
                sawFont = true
                maxSize = max(maxSize, f.pointSize)
                if !fontEmphasis(f).bold { allBold = false }
            }
            if !sawFont { allBold = false; maxSize = bodySize }
            let ratio = maxSize / max(bodySize, 1)

            if isBullet(line) || isNumbered(line) {
                flushPara()
                blocks.append(.list(normalizeList(line)))
                return
            }

            // Heading: clearly larger text, or a short all-bold line that isn't a sentence.
            let isHeading = ratio >= 1.22
                || (allBold && line.count <= 80 && ratio >= 1.04 && !line.hasSuffix("."))
            if isHeading {
                flushPara()
                let level = ratio >= 1.7 ? 1 : (ratio >= 1.35 ? 2 : 3)
                blocks.append(.heading(level, inlineText(attr, lineRange, heading: true)))
                return
            }

            paraBuf.append(inlineText(attr, lineRange, heading: false))   // reflow wrapped lines
        }
        flushPara()

        // Render — headings/paragraphs separated by a blank line; consecutive list items
        // grouped into one tight block.
        var out: [String] = []
        var prevListKind: String? = nil   // "b" bullet / "n" numbered — group same-kind items
        for block in blocks {
            switch block {
            case .heading(let lvl, let t):
                out.append(String(repeating: "#", count: lvl) + " " + t)
                prevListKind = nil
            case .para(let t):
                out.append(t)
                prevListKind = nil
            case .list(let t):
                let kind = t.hasPrefix("- ") ? "b" : "n"
                if prevListKind == kind, let last = out.last {
                    out[out.count - 1] = last + "\n" + t
                } else {
                    out.append(t)
                }
                prevListKind = kind
            }
        }
        return out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: Image → JPEG / PNG (format convert)

    /// Re-encodes an image into `utType` (orientation baked in) written next to the
    /// source with `ext`. Covers HEIC/WebP/PNG → JPEG and friends.
    @discardableResult
    static func convertImage(_ url: URL, to utType: UTType, ext: String) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = orientedImage(from: src) else {
            throw FileToolError.imageUnreadable(url)
        }
        let target = uniqueDestination(url.deletingPathExtension().appendingPathExtension(ext))
        guard let dest = CGImageDestinationCreateWithURL(
            target as CFURL, utType.identifier as CFString, 1, nil
        ) else { throw FileToolError.imageWriteFailed }

        let props: [CFString: Any] = (utType == .jpeg)
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FileToolError.imageWriteFailed }
        return target
    }

    // MARK: Strip image metadata (EXIF / GPS)

    /// Writes a sibling copy with EXIF/GPS/TIFF/IPTC metadata removed. Uses
    /// `AddImageFromSource` so the pixel data is NOT re-encoded — only the metadata
    /// dictionaries are nulled out, keeping the original quality and format.
    @discardableResult
    static func stripImageMetadata(_ url: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let uti = CGImageSourceGetType(src) else {
            throw FileToolError.imageUnreadable(url)
        }
        let ext  = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        let target = uniqueDestination(dir.appendingPathComponent("\(base)-clean.\(ext)"))

        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, uti, 1, nil) else {
            throw FileToolError.imageWriteFailed
        }
        let removals: [CFString: Any] = [
            kCGImagePropertyExifDictionary:    kCFNull,
            kCGImagePropertyGPSDictionary:     kCFNull,
            kCGImagePropertyExifAuxDictionary: kCFNull,
            kCGImagePropertyTIFFDictionary:    kCFNull,
            kCGImagePropertyIPTCDictionary:    kCFNull,
        ]
        CGImageDestinationAddImageFromSource(dest, src, 0, removals as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FileToolError.imageWriteFailed }
        return target
    }

    // MARK: PDF split (one file per page)

    /// Writes each page of a PDF as its own `.pdf` into a new `<name>-pages/` folder
    /// next to the source. Returns the folder (revealed in Finder).
    @discardableResult
    static func splitPDF(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw FileToolError.pdfUnreadable(url) }
        guard doc.pageCount > 0 else { throw FileToolError.pdfEmpty(url) }
        guard doc.pageCount > 1 else { throw FileToolError.pdfSinglePage(url) }

        let base = url.deletingPathExtension().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        let folder = uniqueDestination(dir.appendingPathComponent("\(base)-pages"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let width = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let num = String(format: "%0\(width)d", i + 1)
            let pageURL = folder.appendingPathComponent("\(base)-\(num).pdf")
            guard single.write(to: pageURL) else {
                throw FileToolError.writeFailed("page \(i + 1) could not be saved")
            }
        }
        return folder
    }

    // MARK: PDF → images (one PNG per page)

    /// Renders each page of a PDF to a PNG (at `scale`×) into a `<name>-images/`
    /// folder next to the source. Returns the folder (revealed in Finder).
    @discardableResult
    static func pdfToImages(_ url: URL, scale: CGFloat = 2.0) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw FileToolError.pdfUnreadable(url) }
        guard doc.pageCount > 0 else { throw FileToolError.pdfEmpty(url) }

        let base = url.deletingPathExtension().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        let folder = uniqueDestination(dir.appendingPathComponent("\(base)-images"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let width = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pixelSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: pixelSize, for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let rep  = NSBitmapImageRep(data: tiff),
                  let png  = rep.representation(using: .png, properties: [:]) else {
                throw FileToolError.imageWriteFailed
            }
            let num = String(format: "%0\(width)d", i + 1)
            let pageURL = folder.appendingPathComponent("\(base)-\(num).png")
            do { try png.write(to: pageURL) }
            catch { throw FileToolError.writeFailed(error.localizedDescription) }
        }
        return folder
    }

    // MARK: Images → PDF

    /// Combines every image in `urls` (in order) into one PDF — one image per page —
    /// written next to the first image. Non-image entries are ignored.
    @discardableResult
    static func imagesToPDF(_ urls: [URL]) throws -> URL {
        let images = urls.filter { FileInspector.isImageFile($0) }
        guard let first = images.first else { throw FileToolError.noImages }

        let pdf = PDFDocument()
        var index = 0
        for imgURL in images {
            guard let nsImage = NSImage(contentsOf: imgURL),
                  let page = PDFPage(image: nsImage) else { continue }
            pdf.insert(page, at: index)
            index += 1
        }
        guard index > 0 else { throw FileToolError.imageUnreadable(first) }

        let base = first.deletingPathExtension().lastPathComponent
        let dir  = first.deletingLastPathComponent()
        let target = uniqueDestination(dir.appendingPathComponent("\(base).pdf"))
        guard pdf.write(to: target) else {
            throw FileToolError.writeFailed("PDF could not be saved")
        }
        return target
    }

    // MARK: JSON pretty-print

    /// Re-serialises a JSON file pretty-printed (sorted keys, unescaped slashes) into a
    /// sibling `<name>-pretty.json`.
    @discardableResult
    static func prettyPrintJSON(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw FileToolError.invalidJSON(url)
        }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else { throw FileToolError.invalidJSON(url) }

        let base = url.deletingPathExtension().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        let target = uniqueDestination(dir.appendingPathComponent("\(base)-pretty.json"))
        do { try pretty.write(to: target) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: Compress → .zip

    /// Zips a single file or folder into a sibling `.zip` using the system file
    /// coordinator (`.forUploading`) — the same mechanism Finder's Compress uses.
    @discardableResult
    static func compress(_ url: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileToolError.fileMissing(url) }

        var coordError: NSError?
        var result: URL?
        var innerError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading],
                                       error: &coordError) { zippedURL in
            // `zippedURL` is a temp .zip the coordinator deletes when this block
            // returns — copy it to a stable sibling location first.
            let dir  = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let target = uniqueDestination(dir.appendingPathComponent("\(base).zip"))
            do { try fm.copyItem(at: zippedURL, to: target); result = target }
            catch { innerError = error }
        }
        if let coordError { throw FileToolError.writeFailed(coordError.localizedDescription) }
        if let innerError { throw FileToolError.writeFailed(innerError.localizedDescription) }
        guard let result else { throw FileToolError.writeFailed("the archive could not be created") }
        return result
    }

    // MARK: Text — sort / dedupe lines

    /// Sorts the lines of a text file (case-insensitive, numeric-aware) into a sibling
    /// `<name>-sorted.<ext>`. A trailing newline is preserved.
    @discardableResult
    static func sortLines(_ url: URL) throws -> URL {
        let (lines, trailingNewline) = try splitLines(url)
        let sorted = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let out = sorted.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        return try writeSibling(out, basedOn: url, suffix: "-sorted")
    }

    /// Removes duplicate lines (keeping the first occurrence, original order) into a
    /// sibling `<name>-deduped.<ext>`. A trailing newline is preserved.
    @discardableResult
    static func dedupeLines(_ url: URL) throws -> URL {
        let (lines, trailingNewline) = try splitLines(url)
        var seen = Set<String>()
        var kept: [String] = []
        for line in lines where seen.insert(line).inserted { kept.append(line) }
        let out = kept.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        return try writeSibling(out, basedOn: url, suffix: "-deduped")
    }

    // MARK: Text — count (info, no file)

    /// Returns a human-readable "Lines / Words / Characters" summary string. INFO op —
    /// the caller shows it in an alert with a Copy button rather than writing a file.
    static func countStats(_ url: URL) throws -> String {
        let text = try readText(url)
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // trailing newline isn't a line
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let chars = text.count
        return """
        Lines:       \(lines.count.formatted())
        Words:       \(words.formatted())
        Characters:  \(chars.formatted())
        """
    }

    // MARK: Any file — SHA-256 checksum (info, no file)

    /// Streams the file through SHA-256 (1 MB chunks, so huge files don't load into RAM)
    /// and returns the lowercase hex digest. INFO op — shown in an alert with Copy.
    static func sha256(_ url: URL) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileToolError.fileMissing(url) }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Base64 encode / decode

    /// Base64-encodes the RAW bytes of any file (MIME 76-column wrapping) into a sibling
    /// `<name>.b64`. Works for binary too; the menu gates it to text files for now.
    @discardableResult
    static func base64Encode(_ url: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileToolError.fileMissing(url) }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw FileToolError.notTextReadable(url) }
        let b64 = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let dir  = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let target = uniqueDestination(dir.appendingPathComponent("\(base).b64"))
        do { try b64.write(to: target, atomically: true, encoding: .utf8) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    /// Decodes a Base64 text file (whitespace/newlines ignored). Writes `<name>-decoded.txt`
    /// when the bytes are valid UTF-8, else `<name>-decoded.bin`.
    @discardableResult
    static func base64Decode(_ url: URL) throws -> URL {
        let raw = try readText(url)
        let cleaned = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleaned.isEmpty,
              let data = Data(base64Encoded: cleaned) else {
            throw FileToolError.invalidBase64(url)
        }
        let isText = String(data: data, encoding: .utf8) != nil
        let dir  = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let target = uniqueDestination(dir.appendingPathComponent("\(base)-decoded.\(isText ? "txt" : "bin")"))
        do { try data.write(to: target) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: JSON minify

    /// Re-serialises JSON compactly (no whitespace) into a sibling `<name>-min.json`.
    @discardableResult
    static func minifyJSON(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw FileToolError.invalidJSON(url)
        }
        guard let min = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes, .fragmentsAllowed]
        ) else { throw FileToolError.invalidJSON(url) }
        let dir  = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let target = uniqueDestination(dir.appendingPathComponent("\(base)-min.json"))
        do { try min.write(to: target) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    // MARK: CSV ↔ JSON

    /// Parses an RFC-4180 CSV (first row = headers) into a JSON array of objects written
    /// to a sibling `<name>.json`. Column order is preserved; every value stays a STRING
    /// (CSV has no types) so the round-trip is lossless.
    @discardableResult
    static func csvToJSON(_ url: URL) throws -> URL {
        let text = try readText(url)
        let rows = parseCSV(text)
        guard let header = rows.first, !header.isEmpty else { throw FileToolError.invalidCSV(url) }
        let dataRows = Array(rows.dropFirst())

        var out = "[\n"
        for (i, row) in dataRows.enumerated() {
            let pairs = header.enumerated().map { (c, key) -> String in
                let value = c < row.count ? row[c] : ""
                return "\(jsonStringLiteral(key)): \(jsonStringLiteral(value))"
            }
            out += "  {" + pairs.joined(separator: ", ") + "}"
            out += (i < dataRows.count - 1) ? ",\n" : "\n"
        }
        out += "]\n"

        return try writeSibling(out, basedOn: url, suffix: "", ext: "json")
    }

    /// Flattens a JSON array of objects (or a single object) into an RFC-4180 CSV written
    /// to a sibling `<name>.csv`. Columns = the union of all keys, sorted. Nested
    /// objects/arrays are serialised as compact JSON in their cell.
    @discardableResult
    static func jsonToCSV(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw FileToolError.invalidJSON(url)
        }
        let array: [[String: Any]]
        if let arr = obj as? [[String: Any]] { array = arr }
        else if let single = obj as? [String: Any] { array = [single] }
        else { throw FileToolError.jsonNotTabular(url) }
        guard !array.isEmpty else { throw FileToolError.jsonNotTabular(url) }

        var seen = Set<String>()
        var keys: [String] = []
        for row in array { for key in row.keys where seen.insert(key).inserted { keys.append(key) } }
        keys.sort()

        var lines: [String] = [keys.map(csvField).joined(separator: ",")]
        for row in array {
            let fields = keys.map { key -> String in
                guard let value = row[key] else { return "" }
                return csvField(stringifyJSONValue(value))
            }
            lines.append(fields.joined(separator: ","))
        }
        let out = lines.joined(separator: "\n") + "\n"
        return try writeSibling(out, basedOn: url, suffix: "", ext: "csv")
    }

    // MARK: - Helpers

    /// Decodes an image with its EXIF orientation baked into the pixels (so a rotated
    /// photo re-encodes upright). Falls back to the raw image if dimensions are unknown.
    private static func orientedImage(from src: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth]  as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxPixel = max(w, h)
        if maxPixel > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform:   true,
                kCGImageSourceThumbnailMaxPixelSize:          maxPixel
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return img
            }
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Reads a file as text, trying UTF-8 first, then the platform's best guess, then
    /// Latin-1 (which never fails on byte data). Throws only if the file can't be read.
    private static func readText(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileToolError.fileMissing(url)
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var used: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        throw FileToolError.notTextReadable(url)
    }

    /// Splits a text file into lines, reporting whether it ended with a trailing newline
    /// (so transforms can re-emit it). The trailing-empty element from the split is dropped.
    private static func splitLines(_ url: URL) throws -> (lines: [String], trailingNewline: Bool) {
        let text = try readText(url)
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.last == "" && !text.isEmpty
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    /// Writes UTF-8 `text` next to `url` as `<base><suffix>.<ext>` (ext defaults to the
    /// source extension, or `txt`). Deduped so nothing is clobbered.
    private static func writeSibling(_ text: String, basedOn url: URL,
                                     suffix: String, ext: String? = nil) throws -> URL {
        let dir  = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let useExt = ext ?? (url.pathExtension.isEmpty ? "txt" : url.pathExtension)
        let target = uniqueDestination(dir.appendingPathComponent("\(base)\(suffix).\(useExt)"))
        do { try text.write(to: target, atomically: true, encoding: .utf8) }
        catch { throw FileToolError.writeFailed(error.localizedDescription) }
        return target
    }

    /// JSON string literal with the minimal required escaping (RFC 8259).
    private static func jsonStringLiteral(_ s: String) -> String {
        var r = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if scalar.value < 0x20 { r += String(format: "\\u%04x", scalar.value) }
                else { r.unicodeScalars.append(scalar) }
            }
        }
        return r + "\""
    }

    /// Stringifies a JSON value for a CSV cell: strings verbatim, null → empty, bools →
    /// true/false, numbers → their literal, nested object/array → compact JSON.
    private static func stringifyJSONValue(_ value: Any) -> String {
        if let s = value as? String { return s }
        if value is NSNull { return "" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(value)"
    }

    /// Quotes a CSV field per RFC-4180 when it contains a comma, quote, or newline,
    /// doubling embedded quotes.
    private static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Minimal RFC-4180 CSV parser: handles quoted fields with embedded commas, quotes
    /// (`""`), and newlines, plus `\r\n` / `\r` / `\n` row terminators.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1
                } else { field.append(c); i += 1 }
            } else {
                switch c {
                case "\"": inQuotes = true; i += 1
                case ",":  row.append(field); field = ""; i += 1
                case "\r", "\n":
                    if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    rows.append(row); row = []
                    i += 1
                default:   field.append(c); i += 1
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        // Drop fully-empty trailing rows (e.g. a final blank line).
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }


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
    case pdfToMarkdown
    case markdownToPDF
    case pdfToDocx
    case docxToPDF
    case pdfSplit
    case pdfToImages
    case stitchPDFs
    case convertToJPEG
    case stripEXIF
    case imagesToPDF
    case resizeImage
    case prettyJSON
    case compress
    // Media (batch 2) — local AVFoundation / Speech ops, run async (see `isAsync`).
    case extractAudio
    case transcribe
    case videoToGIF
    case extractFrame
    case compressVideo
    case muteVideo
    case convertToMP4
    case convertToMOV
    case convertToM4A
    // Text / code / data (batch 3) — synchronous Foundation / CryptoKit ops.
    case sortLines
    case dedupeLines
    case countText
    case hashSHA256
    case base64Encode
    case base64Decode
    case minifyJSON
    case csvToJSON
    case jsonToCSV

    var id: String { title }

    /// True for the media ops — they run off the main thread (AVFoundation export, GIF
    /// encode, transcription) and surface a per-row spinner while in flight, so callers
    /// dispatch them via `FileToolActions.performAsync` instead of the sync `perform`.
    var isAsync: Bool {
        switch self {
        case .extractAudio, .transcribe, .videoToGIF, .extractFrame, .compressVideo,
             .muteVideo, .convertToMP4, .convertToMOV, .convertToM4A, .markdownToPDF, .docxToPDF:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .reveal:        return "Show in Finder"
        case .rename:        return "Rename…"
        case .move:          return "Move to…"
        case .pdfToText:     return "Export as .txt"
        case .pdfToMarkdown: return "Export as Markdown"
        case .markdownToPDF: return "Export as PDF"
        case .pdfToDocx:     return "Export as Word (.docx)"
        case .docxToPDF:     return "Export as PDF"
        case .pdfSplit:      return "Split into Pages"
        case .pdfToImages:   return "Pages to Images"
        case .stitchPDFs:    return "Stitch PDFs"
        case .convertToJPEG: return "Convert to JPEG"
        case .stripEXIF:     return "Remove Metadata"
        case .imagesToPDF:   return "Convert to PDF"
        case .resizeImage:   return "Resize / Compress…"
        case .prettyJSON:    return "Pretty-Print JSON"
        case .compress:      return "Compress (.zip)"
        case .extractAudio:  return "Extract Audio"
        case .transcribe:    return "Transcribe"
        case .videoToGIF:    return "Convert to GIF"
        case .extractFrame:  return "Extract Frame"
        case .compressVideo: return "Compress Video"
        case .muteVideo:     return "Remove Audio"
        case .convertToMP4:  return "Convert to MP4"
        case .convertToMOV:  return "Convert to MOV"
        case .convertToM4A:  return "Convert to M4A"
        case .sortLines:     return "Sort Lines"
        case .dedupeLines:   return "Remove Duplicate Lines"
        case .countText:     return "Count Lines / Words"
        case .hashSHA256:    return "SHA-256 Checksum"
        case .base64Encode:  return "Base64 Encode"
        case .base64Decode:  return "Base64 Decode"
        case .minifyJSON:    return "Minify JSON"
        case .csvToJSON:     return "CSV to JSON"
        case .jsonToCSV:     return "JSON to CSV"
        }
    }

    /// Past-tense headline for the utility result stage (Stage.fileResult). Describes
    /// what was just produced ("Compressed", "Converted to JPEG") rather than the verb
    /// offered on the chip. Reveal / rename / move / the INFO ops never reach the
    /// result stage, so they fall back to `.title`.
    var resultTitle: String {
        switch self {
        case .pdfToText:     return "Exported as Text"
        case .pdfToMarkdown: return "Exported as Markdown"
        case .markdownToPDF: return "Exported as PDF"
        case .pdfToDocx:     return "Exported as Word"
        case .docxToPDF:     return "Exported as PDF"
        case .pdfSplit:      return "Split into Pages"
        case .pdfToImages:   return "Pages to Images"
        case .stitchPDFs:    return "Stitched PDFs"
        case .convertToJPEG: return "Converted to JPEG"
        case .stripEXIF:     return "Metadata Removed"
        case .imagesToPDF:   return "Combined into PDF"
        case .resizeImage:   return "Resized Image"
        case .prettyJSON:    return "Pretty-Printed JSON"
        case .compress:      return "Compressed"
        case .extractAudio:  return "Audio Extracted"
        case .transcribe:    return "Transcribed"
        case .videoToGIF:    return "Converted to GIF"
        case .extractFrame:  return "Frame Extracted"
        case .compressVideo: return "Video Compressed"
        case .muteVideo:     return "Audio Removed"
        case .convertToMP4:  return "Converted to MP4"
        case .convertToMOV:  return "Converted to MOV"
        case .convertToM4A:  return "Converted to M4A"
        case .sortLines:     return "Lines Sorted"
        case .dedupeLines:   return "Duplicates Removed"
        case .base64Encode:  return "Base64 Encoded"
        case .base64Decode:  return "Base64 Decoded"
        case .minifyJSON:    return "Minified JSON"
        case .csvToJSON:     return "Converted to JSON"
        case .jsonToCSV:     return "Converted to CSV"
        // Not file-producing result stages; here for switch exhaustiveness.
        case .reveal, .rename, .move, .countText, .hashSHA256:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .reveal:        return "folder"
        case .rename:        return "pencil"
        case .move:          return "arrow.right.doc.on.clipboard"
        case .pdfToText:     return "doc.plaintext"
        case .pdfToMarkdown: return "doc.richtext"
        case .markdownToPDF: return "arrow.up.doc"
        case .pdfToDocx:     return "doc.text"
        case .docxToPDF:     return "arrow.up.doc"
        case .pdfSplit:      return "scissors"
        case .pdfToImages:   return "photo.stack"
        case .stitchPDFs:    return "doc.on.doc"
        case .convertToJPEG: return "photo.on.rectangle"
        case .stripEXIF:     return "location.slash"
        case .imagesToPDF:   return "doc.richtext"
        case .resizeImage:   return "photo"
        case .prettyJSON:    return "curlybraces"
        case .compress:      return "archivebox"
        case .extractAudio:  return "waveform"
        case .transcribe:    return "text.bubble"
        case .videoToGIF:    return "rectangle.stack"
        case .extractFrame:  return "camera"
        case .compressVideo: return "arrow.down.right.and.arrow.up.left"
        case .muteVideo:     return "speaker.slash"
        case .convertToMP4:  return "film"
        case .convertToMOV:  return "film"
        case .convertToM4A:  return "music.note"
        case .sortLines:     return "arrow.up.arrow.down"
        case .dedupeLines:   return "rectangle.compress.vertical"
        case .countText:     return "number"
        case .hashSHA256:    return "barcode"
        case .base64Encode:  return "arrow.up.doc"
        case .base64Decode:  return "arrow.down.doc"
        case .minifyJSON:    return "chevron.left.forwardslash.chevron.right"
        case .csvToJSON:     return "curlybraces"
        case .jsonToCSV:     return "tablecells"
        }
    }

    /// Items valid for `url`, given the full session file list (for Stitch gating).
    static func tools(for url: URL, sessionFiles: [URL]) -> [FileTool] {
        var list: [FileTool] = [.reveal, .rename, .move]
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            list.append(.pdfToText)
            list.append(.pdfToMarkdown)
            list.append(.pdfToDocx)
            list.append(.pdfSplit)
            list.append(.pdfToImages)
            // Stitch is always offered for a PDF; the menu disables it (with a hover
            // hint) until a second PDF is in the session. Gating lives in the menu.
            _ = sessionFiles
            list.append(.stitchPDFs)
        }
        if FileInspector.isImageFile(url) {
            if ext != "jpg" && ext != "jpeg" { list.append(.convertToJPEG) }
            list.append(.stripEXIF)
            list.append(.imagesToPDF)
            list.append(.resizeImage)
        }
        if ext == "json" {
            list.append(.prettyJSON)
            list.append(.minifyJSON)
            list.append(.jsonToCSV)
        }
        if ext == "csv" {
            list.append(.csvToJSON)
        }
        if ext == "md" || ext == "markdown" {
            list.append(.markdownToPDF)
        }
        if ext == "docx" || ext == "doc" {
            list.append(.docxToPDF)
        }
        // Text / code / data (batch 3): line tools + Base64 — synchronous, zero API cost.
        if FileInspector.isTextFile(url) {
            list.append(.sortLines)
            list.append(.dedupeLines)
            list.append(.countText)
            if ext == "b64" || ext == "base64" {
                list.append(.base64Decode)
            } else {
                list.append(.base64Encode)
            }
        }
        // Media (batch 2): local AVFoundation / Speech transforms — zero API cost.
        if FileInspector.isVideoFile(url) {
            list.append(.transcribe)
            list.append(.extractAudio)
            list.append(.videoToGIF)
            list.append(.extractFrame)
            list.append(.compressVideo)
            list.append(.muteVideo)
            if ext != "mp4" { list.append(.convertToMP4) }
            if ext != "mov" { list.append(.convertToMOV) }
        }
        if FileInspector.isAudioFile(url) {
            list.append(.transcribe)
            if ext != "m4a" && ext != "aac" { list.append(.convertToM4A) }
        }
        // Universal: checksum + zip any file or folder.
        list.append(.hashSHA256)
        list.append(.compress)
        return list
    }
}
