import Foundation
import AppKit
import PDFKit

struct FileContentExtractor {

    /// Hard cap on extracted characters so a huge file can't blow the model's
    /// context window. When the source exceeds this, `extract` flags `truncated`
    /// so the UI can tell the user only the first part was analysed.
    static let maxChars = 12_000

    /// Result of an extraction. `truncated` is true when the source was larger
    /// than `maxChars` (or, for PDFs, longer than the 20-page cap) and the text
    /// returned is only the leading slice.
    struct Result {
        let text: String
        let truncated: Bool
    }

    static func extract(from url: URL) async throws -> Result {
        // Under Hardened Runtime, URLs received via drag-and-drop from Finder
        // arrive as security-scoped URLs. startAccessingSecurityScopedResource()
        // is required to read them; for plain path URLs it is a harmless no-op.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try extractPDF(from: url)

        case "rtf", "rtfd", "doc", "docx":
            // Rich-text formats (RTF, Word) — decoded via the Cocoa text system,
            // which reads .docx (Office Open XML) natively. Run on the main actor:
            // the rich-text importers are not guaranteed thread-safe.
            let raw = try await MainActor.run { try extractRichText(from: url) }
            return capped(raw)

        case "png", "jpg", "jpeg", "heic", "webp", "tiff":
            return Result(text: "IMAGE_FILE", truncated: false)

        default:
            // Plain text / code — encoding-detecting read (not just UTF-8).
            return capped(try readText(from: url))
        }
    }

    // MARK: - Format readers

    private static func extractPDF(from url: URL) throws -> Result {
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
        let result = capped(text)
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

    private static func capped(_ text: String) -> Result {
        if text.count > maxChars {
            return Result(text: String(text.prefix(maxChars)), truncated: true)
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
