import Foundation
import NaturalLanguage
import PDFKit

/// Cheap, LOCAL content signals used to make the static suggested-action list content-aware
/// (heuristics only — no network, no LLM). Produced by a BOUNDED, synchronous peek so it can run
/// inline where suggestions are computed (`FileInspector.suggestedActions`) without perceptible
/// latency: text/code read only the first ~16 KB, PDFs only the first page. Every read is
/// best-effort — on any failure the signals are empty (`.none`) and callers fall back to the plain
/// extension-based list.
///
/// Mirrors `FileFacts`' shape: an enum namespace with a nested `Sendable` struct + `nonisolated`
/// statics, so the work is safe to run off the main actor if we ever move it there.
enum FileSignals {

    struct Signals: Sendable {
        /// Dominant natural language of the peeked text, when confidently detected.
        var dominantLanguage: NLLanguage? = nil
        /// ≥ 3 date-like hits (NSDataDetector) — likely an agenda / contract / schedule.
        var hasManyDates = false
        /// Too little text to bother bulleting (drop "Summarise into Bullets").
        var isShort = false
        /// Enough text that summarising should lead.
        var isLong = false
        /// Contains a ``` fence — prose carrying code (offer "Explain This Code").
        var hasCodeFences = false
        /// Invoice/receipt-ish: money keywords or a currency-symbol+digit.
        var isMonetary = false

        // ── Tabular / CSV ─────────────────────────────────────────────────
        /// Header row split into ≥2 columns with a consistent delimiter.
        var looksTabular = false
        /// At least one column whose sampled values parse as numbers → trends/outliers.
        var hasNumericColumns = false

        // ── Text flavour ──────────────────────────────────────────────────
        /// Greeting + sign-off, or From/To/Subject headers → offer "Draft Reply".
        var looksLikeEmail = false
        /// `- [ ]` / TODO markers → offer "Extract To-Dos".
        var hasTodoMarkers = false
        /// Short bulleted lines, little running prose → notes (slides / post / brief).
        var looksLikeNotes = false

        /// Empty signals — every flag false, no language. The safe fallback.
        static let none = Signals()
    }

    // Bounds: enough text to detect language/structure, never enough to stall the drop.
    private static let maxPeekBytes   = 16_384   // text/code prefix
    private static let shortThreshold = 280      // chars → "too little to bullet"
    private static let longThreshold  = 4_000    // chars → "summarise leads"
    private static let manyDatesHits  = 3

    /// Peek a capped prefix of `url`'s content and derive signals. Text/code read the first
    /// ~16 KB via `FileHandle`; PDFs read only the first page string; anything else → `.none`.
    nonisolated static func peek(_ url: URL) -> Signals {
        guard let text = peekText(url) else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        return analyse(trimmed, ext: url.pathExtension.lowercased())
    }

    // MARK: - Bounded content read

    private nonisolated static func peekText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            // First page only — cheap relative to the whole document.
            guard let doc = PDFDocument(url: url), doc.pageCount > 0,
                  let page = doc.page(at: 0) else { return nil }
            return page.string
        }
        if FileInspector.isTextFile(url) || ["txt", "md", "rtf", "csv", "tsv"].contains(ext) {
            return readPrefix(url)
        }
        return nil
    }

    /// First `maxPeekBytes` of the file as (lossy) UTF-8, via `FileHandle` so we never read a huge
    /// file whole. Returns nil on any error.
    private nonisolated static func readPrefix(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: maxPeekBytes)) ?? nil,
              !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Analysis

    private nonisolated static func analyse(_ text: String, ext: String) -> Signals {
        var s = Signals()
        let count = text.count
        s.isShort = count < shortThreshold
        s.isLong  = count >= longThreshold

        // Language — only trust a guess on enough text.
        if count >= 40 {
            let rec = NLLanguageRecognizer()
            rec.processString(text)
            if let lang = rec.dominantLanguage, lang != .undetermined {
                s.dominantLanguage = lang
            }
        }

        s.hasCodeFences = text.contains("```")
        s.isMonetary    = matchesMonetary(text)
        s.hasManyDates  = dateHitCount(text) >= manyDatesHits

        // Tabular structure (csv/tsv, or any text that clearly is a delimited table).
        analyseTabular(text, ext: ext, into: &s)

        // Text flavour (skip on obvious tables — a CSV isn't an email).
        if !s.looksTabular {
            s.looksLikeEmail  = matchesEmail(text)
            s.hasTodoMarkers  = matchesTodos(text)
            s.looksLikeNotes  = matchesNotes(text)
        }
        return s
    }

    /// Detect a delimited table and whether it has numeric columns. Samples only the
    /// first handful of lines from the already-bounded peek.
    private nonisolated static func analyseTabular(_ text: String, ext: String, into s: inout Signals) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(12)
        guard let header = lines.first, lines.count >= 2 else { return }

        // Pick the delimiter that splits the header into the most fields.
        let candidates: [Character] = [",", ";", "\t"]
        let bestDelim = candidates.max { a, b in
            header.filter { $0 == a }.count < header.filter { $0 == b }.count
        } ?? ","

        let cols = header.split(separator: bestDelim, omittingEmptySubsequences: false).count
        guard cols >= 2 else { return }
        // A file explicitly csv/tsv, OR consistent column counts across rows.
        let rowCols = lines.dropFirst().map {
            $0.split(separator: bestDelim, omittingEmptySubsequences: false).count
        }
        let consistent = rowCols.filter { $0 == cols }.count >= max(1, rowCols.count - 1)
        guard ["csv", "tsv"].contains(ext) || consistent else { return }
        s.looksTabular = true

        // Numeric columns: scan sampled data cells for parseable numbers.
        var numericHits = 0
        for line in lines.dropFirst() {
            for cell in line.split(separator: bestDelim, omittingEmptySubsequences: false) {
                let v = cell.trimmingCharacters(in: CharacterSet(charactersIn: " \"'$€£%"))
                    .replacingOccurrences(of: ",", with: "")
                if !v.isEmpty, Double(v) != nil { numericHits += 1 }
            }
        }
        s.hasNumericColumns = numericHits >= 3
    }

    private nonisolated static func matchesEmail(_ text: String) -> Bool {
        let head = text.prefix(400).lowercased()
        if head.contains("from:") && head.contains("subject:") { return true }
        let greetings = ["dear ", "hi ", "hello ", "hey ", "guten tag", "sehr geehrte"]
        let signoffs  = ["regards", "best,", "best regards", "sincerely", "cheers,",
                         "thanks,", "thank you,", "kind regards", "mit freundlichen"]
        let lower = text.lowercased()
        return greetings.contains(where: head.contains)
            && signoffs.contains(where: lower.contains)
    }

    private nonisolated static func matchesTodos(_ text: String) -> Bool {
        if text.range(of: #"[-*]\s?\[[ xX]?\]"#, options: .regularExpression) != nil { return true }
        // A couple of lines beginning with TODO/FIXME or an action checkbox.
        let hits = text.split(separator: "\n").prefix(40).filter {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("todo") || l.hasPrefix("- todo") || l.hasPrefix("[]") || l.hasPrefix("☐")
        }.count
        return hits >= 2
    }

    private nonisolated static func matchesNotes(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 5 else { return false }
        let bullets = lines.filter {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") || l.hasPrefix("#")
        }.count
        let shortLines = lines.filter { $0.count < 70 }.count
        // Mostly short lines and a decent share of bullets/headers = notes, not prose.
        return bullets >= 3 && shortLines >= (lines.count * 2 / 3)
    }

    private nonisolated static func matchesMonetary(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["invoice", "amount due", "subtotal", "balance due",
                        "total due", "vat", " tax "]
        if keywords.contains(where: lower.contains) { return true }
        // A currency symbol immediately followed by a digit (e.g. "$1,200", "€9").
        return text.range(of: #"[$€£¥]\s?\d"#, options: .regularExpression) != nil
    }

    /// Count date-ish hits with `NSDataDetector` (handles many formats) over the bounded peek.
    private nonisolated static func dateHitCount(_ text: String) -> Int {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.numberOfMatches(in: text, options: [], range: range)
    }
}
