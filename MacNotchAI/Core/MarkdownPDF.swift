import AppKit
import WebKit

/// Markdown → PDF, pure-Apple and local: a small hand-rolled Markdown→HTML converter feeds a
/// styled HTML document into an offscreen `WKWebView`, captured as ONE tall page via
/// `WKWebView.pdf()` (createPDF — bounded, no infinite-pagination risk), then re-paginated with
/// CoreGraphics into margined pages at the system default paper size (Letter/A4 follow the user's
/// locale). No third-party deps. The round-trip partner of `exportPDFMarkdown`.
@MainActor
enum MarkdownPDF {

    /// Read `url` (a `.md`), convert, and write a sibling `.pdf`. Async — WebKit load + print.
    static func export(_ url: URL) async throws -> URL {
        let md = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url))   // best-effort for non-UTF8
            ?? ""
        let title = url.deletingPathExtension().lastPathComponent
        let html = htmlDocument(body: markdownToHTML(md), title: title)
        let target = uniqueDestination(url.deletingPathExtension().appendingPathExtension("pdf"))
        try await renderPDF(html: html, baseURL: url.deletingLastPathComponent(), to: target)
        return target
    }

    /// Word `.docx`/`.doc` → PDF. Reads the document into an `NSAttributedString` (Apple's
    /// built-in OfficeOpenXML reader — preserves text, headings, bold/italic, lists, basic
    /// tables/images), exports it as HTML, then runs the same WebKit → paginated-PDF pipeline.
    static func exportDocxToPDF(_ url: URL) async throws -> URL {
        let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        let htmlData = try attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let html = String(decoding: htmlData, as: UTF8.self)
        let target = uniqueDestination(url.deletingPathExtension().appendingPathExtension("pdf"))
        try await renderPDF(html: html, baseURL: url.deletingLastPathComponent(), to: target)
        return target
    }

    // MARK: - WebKit render → PDF

    private static func renderPDF(html: String, baseURL: URL, to target: URL) async throws {
        // Output page size from the user's locale default (Letter / A4).
        let pageSize = NSPrintInfo().paperSize
        let margin: CGFloat = 48
        let contentWidth = max(200, pageSize.width - margin * 2)

        // Render at the content width → createPDF gives ONE tall page (bounded; no print loop).
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: pageSize.height))
        let delegate = LoadDelegate()
        webView.navigationDelegate = delegate
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.completion = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)   // settle fonts/images/layout

        let data = try await webView.pdf(configuration: WKPDFConfiguration())   // full content, one page
        try paginate(data, pageSize: pageSize, margin: margin, contentWidth: contentWidth, to: target)
    }

    /// Slice the single tall page from `createPDF` into fixed-size, margined pages with CoreGraphics.
    private static func paginate(_ data: Data, pageSize: CGSize, margin: CGFloat,
                                 contentWidth: CGFloat, to target: URL) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let srcDoc = CGPDFDocument(provider),
              let srcPage = srcDoc.page(at: 1) else {
            throw FileToolError.writeFailed("Could not render the PDF.")
        }
        let totalHeight = srcPage.getBoxRect(.mediaBox).height
        let contentHeight = max(1, pageSize.height - margin * 2)
        let pageCount = max(1, Int(ceil(totalHeight / contentHeight)))

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: target as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FileToolError.writeFailed("Could not write the PDF.")
        }

        for k in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Clip to the content area (inside the page margins).
            ctx.clip(to: CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight))
            // Map slice k (top-first): the source content top of this slice lands at the top of
            // the content area. Source y grows upward, so the first page shows the highest content.
            let ty = (margin + contentHeight) - (totalHeight - CGFloat(k) * contentHeight)
            ctx.translateBy(x: margin, y: ty)
            ctx.drawPDFPage(srcPage)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        var completion: ((Result<Void, Error>) -> Void)?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(.success(())) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(.failure(e)) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(.failure(e)) }
        private func finish(_ r: Result<Void, Error>) { completion?(r); completion = nil }
    }

    // MARK: - Dedupe (local copy so we don't depend on FileTools internals)

    private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - HTML document shell

    private static func htmlDocument(body: String, title: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
        <style>
        * { -webkit-print-color-adjust: exact; }
        body { font: 13px/1.55 -apple-system, "Helvetica Neue", Arial, sans-serif; color:#1d1d1f; margin:0; }
        h1 { font-size:2em; margin:0.3em 0 0.3em; font-weight:700; }
        h2 { font-size:1.5em; margin:0.9em 0 0.3em; font-weight:700; border-bottom:1px solid #e5e5e7; padding-bottom:0.15em; }
        h3 { font-size:1.2em; margin:0.8em 0 0.25em; font-weight:600; }
        h4,h5,h6 { margin:0.7em 0 0.2em; font-weight:600; }
        p { margin:0.5em 0; }
        ul,ol { margin:0.5em 0 0.5em 1.5em; padding:0; }
        li { margin:0.2em 0; }
        code { font-family:"SF Mono",Menlo,monospace; font-size:0.88em; background:#f4f4f6; padding:0.1em 0.3em; border-radius:4px; }
        pre { background:#f4f4f6; padding:0.8em 1em; border-radius:8px; overflow:auto; white-space:pre-wrap; word-wrap:break-word; }
        pre code { background:none; padding:0; }
        blockquote { margin:0.6em 0; padding:0.2em 0 0.2em 1em; border-left:3px solid #d0d0d5; color:#555; }
        hr { border:none; border-top:1px solid #e5e5e7; margin:1.2em 0; }
        a { color:#0a84ff; text-decoration:none; }
        table { border-collapse:collapse; margin:0.7em 0; width:100%; font-size:0.95em; }
        th,td { border:1px solid #e0e0e3; padding:6px 10px; text-align:left; vertical-align:top; }
        th { background:#f4f4f6; font-weight:600; }
        img { max-width:100%; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    // MARK: - Markdown → HTML (bounded subset: headings, lists, code, quotes, tables, inline)

    static func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html = ""
        var listKind: String? = nil           // "ul"/"ol" currently open
        var paraBuf: [String] = []
        var i = 0

        func closeList() { if let k = listKind { html += "</\(k)>\n"; listKind = nil } }
        func flushPara() {
            if !paraBuf.isEmpty {
                html += "<p>\(inlineHTML(paraBuf.joined(separator: " ")))</p>\n"
                paraBuf.removeAll()
            }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block ``` … ```
            if line.hasPrefix("```") {
                flushPara(); closeList()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                html += "<pre><code>\(escapeHTML(code.joined(separator: "\n")))</code></pre>\n"
                i += 1   // skip closing fence
                continue
            }

            if line.isEmpty { flushPara(); closeList(); i += 1; continue }

            if line == "---" || line == "***" || line == "___" {
                flushPara(); closeList(); html += "<hr />\n"; i += 1; continue
            }

            if let level = headingLevel(line) {
                flushPara(); closeList()
                let content = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>\(inlineHTML(content))</h\(level)>\n"
                i += 1; continue
            }

            // GFM table: header row + separator row.
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara(); closeList()
                let header = tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(tableCells(lines[i])); i += 1
                }
                html += renderTable(header: header, rows: rows)
                continue
            }

            if line.hasPrefix(">") {
                flushPara(); closeList()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    quote.append(q.trimmingCharacters(in: .whitespaces)); i += 1
                }
                html += "<blockquote>\(inlineHTML(quote.joined(separator: " ")))</blockquote>\n"
                continue
            }

            if isUnorderedItem(line) {
                flushPara()
                if listKind != "ul" { closeList(); html += "<ul>\n"; listKind = "ul" }
                html += "<li>\(inlineHTML(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</li>\n"
                i += 1; continue
            }
            if isOrderedItem(line) {
                flushPara()
                if listKind != "ol" { closeList(); html += "<ol>\n"; listKind = "ol" }
                html += "<li>\(inlineHTML(orderedContent(line)))</li>\n"
                i += 1; continue
            }

            // Paragraph text (reflow wrapped lines).
            closeList()
            paraBuf.append(line)
            i += 1
        }
        flushPara(); closeList()
        return html
    }

    // MARK: Block helpers

    private static func headingLevel(_ line: String) -> Int? {
        var n = 0
        for ch in line { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n) else { return nil }
        let idx = line.index(line.startIndex, offsetBy: n)
        return idx < line.endIndex && line[idx] == " " ? n : nil
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        guard let f = line.first, f == "-" || f == "*" || f == "+" else { return false }
        return line.dropFirst().first == " "
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        var idx = line.startIndex; var d = false
        while idx < line.endIndex, line[idx].isNumber { d = true; idx = line.index(after: idx) }
        guard d, idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return false }
        idx = line.index(after: idx)
        return idx < line.endIndex && line[idx] == " "
    }

    private static func orderedContent(_ line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber { idx = line.index(after: idx) }
        if idx < line.endIndex { idx = line.index(after: idx) }   // skip . or )
        return String(line[idx...]).trimmingCharacters(in: .whitespaces)
    }

    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.allSatisfy({ "-:| ".contains($0) }) else { return false }
        let cells = tableCells(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { c in
            !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
        }
    }

    private static func renderTable(header: [String], rows: [[String]]) -> String {
        var h = "<table>\n<thead><tr>"
        for c in header { h += "<th>\(inlineHTML(c))</th>" }
        h += "</tr></thead>\n<tbody>\n"
        for r in rows {
            h += "<tr>"
            for c in r { h += "<td>\(inlineHTML(c))</td>" }
            h += "</tr>\n"
        }
        h += "</tbody></table>\n"
        return h
    }

    // MARK: Inline

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    /// Inline Markdown → HTML. Code spans are protected first (so emphasis can't bleed into
    /// them), then text is escaped, then images/links/bold/italic are applied, then code restored.
    private static func inlineHTML(_ s: String) -> String {
        // 1) pull out `code` spans
        var codes: [String] = []
        var text = s
        if let re = try? NSRegularExpression(pattern: "`([^`]+)`") {
            let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches.reversed() {
                guard let full = Range(m.range, in: text), let g = Range(m.range(at: 1), in: text) else { continue }
                codes.append(String(text[g]))
                text.replaceSubrange(full, with: "\u{0000}C\(codes.count - 1)\u{0000}")
            }
        }
        // 2) escape, then inline transforms
        text = escapeHTML(text)
        text = regexReplace(text, #"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\" />")
        text = regexReplace(text, #"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
        text = regexReplace(text, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        text = regexReplace(text, #"__([^_]+)__"#, "<strong>$1</strong>")
        text = regexReplace(text, #"\*([^*]+)\*"#, "<em>$1</em>")
        text = regexReplace(text, #"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])"#, "<em>$1</em>")
        // 3) restore code spans — placeholder Ck maps to codes[k] (set at insertion time).
        for idx in 0..<codes.count {
            text = text.replacingOccurrences(of: "\u{0000}C\(idx)\u{0000}",
                                             with: "<code>\(escapeHTML(codes[idx]))</code>")
        }
        return text
    }
}
