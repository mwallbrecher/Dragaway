import Foundation
import AppKit
import PDFKit

struct FileContentExtractor {

    /// Hard cap on extracted characters. Bounds input-token cost (input dominates
    /// document tasks) and keeps the client under the Worker's per-request ceiling.
    /// When the source exceeds the active cap, `extract` flags `truncated` so the UI
    /// can tell the user only the first part was analysed. **Free / BYOK tier.**
    static let maxChars = 24_000

    /// Pro / subscriber char cap — double the free cap. Longer documents are analysed
    /// in full, at proportionally higher input cost. The active cap is chosen at the
    /// call site from the entitlement (see `buildMultiFileContent`) and matched by the
    /// Worker's server-verified Pro ceiling (`MAX_CONTENT_CHARS_PRO`).
    static let maxCharsPro = 48_000

    /// Result of an extraction. `truncated` is true when the source was larger
    /// than the active char cap (or, for PDFs, longer than the 20-page cap) and the
    /// text returned is only the leading slice.
    struct Result {
        let text: String
        let truncated: Bool
    }

    /// - Parameter limit: char cap to apply (defaults to the free-tier `maxChars`;
    ///   callers pass `maxCharsPro` for entitled users).
    static func extract(from url: URL, limit: Int = FileContentExtractor.maxChars) async throws -> Result {
        // Under Hardened Runtime, URLs received via drag-and-drop from Finder
        // arrive as security-scoped URLs. startAccessingSecurityScopedResource()
        // is required to read them; for plain path URLs it is a harmless no-op.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "eml", "emlx":
            // MIME traversal + HTML cleanup can touch several MiB. Keep it off the
            // default MainActor while the security scope remains active in this call.
            let extracted = try await Task.detached(priority: .userInitiated) {
                let email = try EmailContentExtractor.extract(from: url)
                let readableBody = email.bodyIsHTML
                    ? EmailContentExtractor.plainText(fromHTML: email.body)
                    : email.body
                return (email.formattedText(body: readableBody), email.sourceTruncated)
            }.value
            let result = capped(extracted.0, limit: limit)
            return Result(
                text: result.text,
                truncated: result.truncated || extracted.1
            )

        case "pdf":
            return try extractPDF(from: url, limit: limit)

        case "rtf", "rtfd", "doc", "docx":
            // Rich-text formats (RTF, Word) — decoded via the Cocoa text system,
            // which reads .docx (Office Open XML) natively. Run on the main actor:
            // the rich-text importers are not guaranteed thread-safe.
            let raw = try await MainActor.run { try extractRichText(from: url) }
            return capped(raw, limit: limit)

        case "png", "jpg", "jpeg", "heic", "webp", "tiff":
            return Result(text: "IMAGE_FILE", truncated: false)

        default:
            // Plain text / code — encoding-detecting read (not just UTF-8).
            return capped(try readText(from: url), limit: limit)
        }
    }

    // MARK: - Format readers

    private static func extractPDF(from url: URL, limit: Int) throws -> Result {
        // Security scope is already active from the caller (extract).
        guard let pdf = PDFDocument(url: url) else {
            throw ExtractionError.cannotOpenPDF
        }
        let maxPages = min(pdf.pageCount, 20)
        var text = ""
        for i in 0..<maxPages {
            if let page = pdf.page(at: i) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.pdfHasNoText
        }
        // Truncated if we skipped pages OR the text overflows the char cap.
        let pagesSkipped = pdf.pageCount > maxPages
        let result = capped(text, limit: limit)
        return Result(text: result.text, truncated: result.truncated || pagesSkipped)
    }

    /// Decodes RTF / DOC / DOCX into plain text via NSAttributedString.
    /// Must run on the main actor (the AppKit rich-text importers are not
    /// documented as thread-safe).
    @MainActor
    private static func extractRichText(from url: URL) throws -> String {
        guard let attr = try? NSAttributedString(
            url: url,
            options: [:],
            documentAttributes: nil
        ) else {
            throw ExtractionError.cannotReadDocument
        }
        let text = attr.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.cannotReadDocument
        }
        return text
    }

    /// Reads a text file, detecting the encoding instead of assuming UTF-8.
    /// Falls back through auto-detection → Latin-1 → lossy UTF-8 so non-UTF-8
    /// files (latin-1, etc.) no longer throw.
    private static func readText(from url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }

        var used: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }

        // Last resort: decode raw bytes. isoLatin1 maps every byte 1:1, and
        // the UTF-8 lossy path never throws — so we always return *something*.
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    private static func capped(_ text: String, limit: Int) -> Result {
        if text.count > limit {
            return Result(text: String(text.prefix(limit)), truncated: true)
        }
        return Result(text: text, truncated: false)
    }

    enum ExtractionError: LocalizedError {
        case cannotOpenPDF
        case pdfHasNoText
        case cannotReadDocument
        case unsupportedFileType

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF:       return "Could not open the PDF file."
            case .pdfHasNoText:        return "This PDF appears to contain only images. Try an image action instead."
            case .cannotReadDocument:  return "Could not read text from this document."
            case .unsupportedFileType: return "This file type is not yet supported."
            }
        }
    }
}
