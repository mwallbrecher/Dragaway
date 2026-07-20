import Foundation

/// Bounded, local RFC 5322 / MIME reader for messages dragged out of Mail.
///
/// The parser deliberately returns the selected HTML body as HTML. Callers convert
/// it with the no-I/O `plainText(fromHTML:)` sanitizer below; AppKit's HTML importer
/// is intentionally avoided because it can load remote email-tracking resources.
enum EmailContentExtractor {

    struct Result: Sendable {
        let subject: String?
        let from: String?
        let to: String?
        let cc: String?
        let date: String?
        let body: String
        let bodyIsHTML: Bool
        /// True when the original RFC message exceeded `byteLimit` and only its
        /// leading bytes were available to the MIME parser.
        let sourceTruncated: Bool

        /// Produces model-ready context after an optional HTML-to-text conversion.
        /// Passing `nil` keeps the parser's body unchanged.
        nonisolated func formattedText(body bodyOverride: String? = nil) -> String {
            var lines: [String] = []
            if let subject, !subject.isEmpty { lines.append("Subject: \(subject)") }
            if let from, !from.isEmpty       { lines.append("From: \(from)") }
            if let to, !to.isEmpty           { lines.append("To: \(to)") }
            if let cc, !cc.isEmpty           { lines.append("Cc: \(cc)") }
            if let date, !date.isEmpty       { lines.append("Date: \(date)") }

            let selectedBody = (bodyOverride ?? body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedBody.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Message:")
                lines.append(selectedBody)
            }
            return lines.joined(separator: "\n")
        }
    }

    enum ParseError: LocalizedError {
        case invalidByteLimit
        case emptyMessage
        case noReadableContent

        var errorDescription: String? {
            switch self {
            case .invalidByteLimit:
                return "The email read limit must be greater than zero."
            case .emptyMessage:
                return "The email file is empty."
            case .noReadableContent:
                return "The email contains no readable message text."
            }
        }
    }

    /// Reads at most four MiB of RFC message data by default. This is large enough
    /// for normal text bodies while preventing a dragged message's attachments from
    /// turning extraction into an unbounded file read.
    nonisolated static func extract(
        from url: URL,
        byteLimit: Int = 4 * 1024 * 1024
    ) throws -> Result {
        guard byteLimit > 0 else { throw ParseError.invalidByteLimit }

        let loaded = try readMessageData(from: url, byteLimit: byteLimit)
        guard !loaded.data.isEmpty else { throw ParseError.emptyMessage }

        let root = parseEntity(loaded.data)
        let candidates = bodyCandidates(in: root, depth: 0)
        let selected = candidates.first(where: { $0.rank == 0 })
            ?? candidates.first(where: { $0.rank == 1 })
            ?? candidates.first(where: { $0.rank == 2 })

        let headers = root.headers
        let subject = decodedHeader(headers.first("subject"))
        let from = decodedHeader(headers.first("from"))
        let to = decodedHeader(headers.joined("to"))
        let cc = decodedHeader(headers.joined("cc"))
        let date = decodedHeader(headers.first("date"))

        let body = selected?.text ?? ""
        let hasHeaderContext = [subject, from, to, cc, date].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasHeaderContext || !body.isEmpty else {
            throw ParseError.noReadableContent
        }

        return Result(
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            date: date,
            body: body,
            bodyIsHTML: selected?.isHTML ?? false,
            sourceTruncated: loaded.truncated
        )
    }

    /// Converts a decoded MIME `text/html` body into readable text without using
    /// AppKit/WebKit. `NSAttributedString`'s HTML importer may fetch remote CSS and
    /// images, which would trigger email tracking pixels during extraction. This
    /// bounded string pass performs no I/O and therefore keeps mail reading local.
    nonisolated static func plainText(fromHTML html: String) -> String {
        var text = html

        text = text.replacingOccurrences(
            of: #"(?s)<!--.*?(?:-->|$)"#,
            with: "",
            options: .regularExpression
        )

        // Remove content that is not visible message prose. The end-of-string
        // alternative also handles malformed/truncated HTML safely.
        for tag in ["head", "script", "style", "template", "svg", "noscript"] {
            text = text.replacingOccurrences(
                of: #"(?is)<\#(tag)\b[^>]*>.*?(?:</\#(tag)\s*>|$)"#,
                with: "",
                options: .regularExpression
            )
        }

        // Preserve the useful shape of paragraphs, lists, and simple tables before
        // stripping every remaining tag.
        text = text.replacingOccurrences(
            of: #"(?i)<br\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)<li\b[^>]*>"#,
            with: "\n• ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)</li\s*>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)</?(?:td|th)\b[^>]*>"#,
            with: "\t",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)</?(?:p|div|section|article|header|footer|aside|h[1-6]|ul|ol|dl|dt|dd|blockquote|pre|address|tr|table|hr)\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?s)<[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        text = decodeHTMLEntities(text)

        let lines = normaliseNewlines(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                String(line)
                    .replacingOccurrences(
                        of: #"[\t \u{00A0}]+"#,
                        with: " ",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespaces)
            }

        var cleaned: [String] = []
        for line in lines {
            if line.isEmpty, cleaned.last?.isEmpty == true { continue }
            cleaned.append(line)
        }
        while cleaned.first?.isEmpty == true { cleaned.removeFirst() }
        while cleaned.last?.isEmpty == true { cleaned.removeLast() }
        return cleaned.joined(separator: "\n")
    }

    private nonisolated static func decodeHTMLEntities(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex

        while let ampersand = text[cursor...].firstIndex(of: "&") {
            output.append(contentsOf: text[cursor..<ampersand])
            let valueStart = text.index(after: ampersand)
            let boundedTail = text[valueStart...].prefix(32)
            guard let semicolon = boundedTail.firstIndex(of: ";") else {
                output.append("&")
                cursor = valueStart
                continue
            }

            let name = String(text[valueStart..<semicolon])
            if let decoded = decodedHTMLEntity(named: name) {
                output.append(contentsOf: decoded)
                cursor = text.index(after: semicolon)
            } else {
                output.append("&")
                cursor = valueStart
            }
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    private nonisolated static func decodedHTMLEntity(named raw: String) -> String? {
        let name = raw.lowercased()
        if name.hasPrefix("#x"),
           let value = UInt32(name.dropFirst(2), radix: 16),
           let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        if name.hasPrefix("#"),
           let value = UInt32(name.dropFirst(), radix: 10),
           let scalar = UnicodeScalar(value) {
            return String(scalar)
        }

        // HTML's Latin-1 entity names are case-sensitive (`Auml` ≠ `auml`).
        // These are common in European email generated by older clients.
        switch raw {
        case "Agrave": return "À"
        case "Aacute": return "Á"
        case "Acirc":  return "Â"
        case "Atilde": return "Ã"
        case "Auml":   return "Ä"
        case "Aring":  return "Å"
        case "AElig":  return "Æ"
        case "Ccedil": return "Ç"
        case "Egrave": return "È"
        case "Eacute": return "É"
        case "Ecirc":  return "Ê"
        case "Euml":   return "Ë"
        case "Igrave": return "Ì"
        case "Iacute": return "Í"
        case "Icirc":  return "Î"
        case "Iuml":   return "Ï"
        case "ETH":    return "Ð"
        case "Ntilde": return "Ñ"
        case "Ograve": return "Ò"
        case "Oacute": return "Ó"
        case "Ocirc":  return "Ô"
        case "Otilde": return "Õ"
        case "Ouml":   return "Ö"
        case "Oslash": return "Ø"
        case "Ugrave": return "Ù"
        case "Uacute": return "Ú"
        case "Ucirc":  return "Û"
        case "Uuml":   return "Ü"
        case "Yacute": return "Ý"
        case "THORN":  return "Þ"
        case "agrave": return "à"
        case "aacute": return "á"
        case "acirc":  return "â"
        case "atilde": return "ã"
        case "auml":   return "ä"
        case "aring":  return "å"
        case "aelig":  return "æ"
        case "ccedil": return "ç"
        case "egrave": return "è"
        case "eacute": return "é"
        case "ecirc":  return "ê"
        case "euml":   return "ë"
        case "igrave": return "ì"
        case "iacute": return "í"
        case "icirc":  return "î"
        case "iuml":   return "ï"
        case "eth":    return "ð"
        case "ntilde": return "ñ"
        case "ograve": return "ò"
        case "oacute": return "ó"
        case "ocirc":  return "ô"
        case "otilde": return "õ"
        case "ouml":   return "ö"
        case "oslash": return "ø"
        case "ugrave": return "ù"
        case "uacute": return "ú"
        case "ucirc":  return "û"
        case "uuml":   return "ü"
        case "yacute": return "ý"
        case "thorn":  return "þ"
        case "yuml":   return "ÿ"
        case "szlig":  return "ß"
        default: break
        }

        switch name {
        case "amp":    return "&"
        case "lt":     return "<"
        case "gt":     return ">"
        case "quot":   return "\""
        case "apos":   return "'"
        case "nbsp", "ensp", "emsp", "thinsp": return " "
        case "ndash":  return "–"
        case "mdash":  return "—"
        case "hellip": return "…"
        case "lsquo":  return "‘"
        case "rsquo":  return "’"
        case "ldquo":  return "“"
        case "rdquo":  return "”"
        case "laquo":  return "«"
        case "raquo":  return "»"
        case "bull":   return "•"
        case "middot": return "·"
        case "copy":   return "©"
        case "reg":    return "®"
        case "trade":  return "™"
        case "euro":   return "€"
        case "pound":  return "£"
        case "yen":    return "¥"
        case "cent":   return "¢"
        case "shy":    return ""
        case "zwnj":   return "\u{200C}"
        case "zwj":    return "\u{200D}"
        default:         return nil
        }
    }

    // MARK: - Bounded input

    private struct LoadedMessage: Sendable {
        let data: Data
        let truncated: Bool
    }

    private nonisolated static func readMessageData(
        from url: URL,
        byteLimit: Int
    ) throws -> LoadedMessage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // `.emlx` starts with a decimal byte count before the RFC message. Reserve
        // a small prefix allowance so that count does not eat into `byteLimit`.
        let prefixAllowance = 1_024
        let readLimit: Int
        if byteLimit > Int.max - prefixAllowance - 1 {
            readLimit = Int.max
        } else {
            readLimit = byteLimit + prefixAllowance + 1
        }
        let raw = try handle.read(upToCount: readLimit) ?? Data()
        guard !raw.isEmpty else { return LoadedMessage(data: Data(), truncated: false) }

        if url.pathExtension.lowercased() == "emlx",
           let lineEnd = raw.firstIndex(of: 0x0A) {
            let countData = raw[..<lineEnd]
            let countString = String(decoding: countData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let declaredLength = Int(countString), declaredLength >= 0 {
                let messageStart = raw.index(after: lineEnd)
                let available = raw.distance(from: messageStart, to: raw.endIndex)
                let wanted = min(declaredLength, byteLimit)
                let take = min(available, wanted)
                let end = raw.index(messageStart, offsetBy: take)
                return LoadedMessage(
                    data: Data(raw[messageStart..<end]),
                    truncated: declaredLength > take
                )
            }
        }

        let take = min(raw.count, byteLimit)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? raw.count
        return LoadedMessage(
            data: Data(raw.prefix(take)),
            truncated: fileSize > take || raw.count > take
        )
    }

    // MARK: - MIME tree

    private struct Headers: Sendable {
        var values: [String: [String]] = [:]

        nonisolated init(values: [String: [String]] = [:]) {
            self.values = values
        }

        nonisolated func first(_ name: String) -> String? {
            values[name.lowercased()]?.first
        }

        nonisolated func joined(_ name: String) -> String? {
            guard let all = values[name.lowercased()], !all.isEmpty else { return nil }
            return all.joined(separator: ", ")
        }
    }

    private struct Entity: Sendable {
        let headers: Headers
        let body: Data
    }

    /// Rank 0 = text/plain, 1 = text/html, 2 = another non-attachment text subtype.
    private struct BodyCandidate: Sendable {
        let text: String
        let isHTML: Bool
        let rank: Int
    }

    private struct HeaderValue: Sendable {
        let value: String
        let parameters: [String: String]
    }

    private nonisolated static func parseEntity(_ data: Data) -> Entity {
        guard let split = headerBodySplit(in: data) else {
            // RFC 2045's default media type is text/plain, so a headerless payload
            // is still useful rather than being rejected outright.
            return Entity(headers: Headers(), body: data)
        }
        let headerData = data[..<split.headerEnd]
        let bodyData = data[split.bodyStart...]
        return Entity(headers: parseHeaders(Data(headerData)), body: Data(bodyData))
    }

    private nonisolated static func headerBodySplit(
        in data: Data
    ) -> (headerEnd: Data.Index, bodyStart: Data.Index)? {
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        if let range = data.range(of: crlf) {
            return (range.lowerBound, range.upperBound)
        }
        let lf = Data([0x0A, 0x0A])
        if let range = data.range(of: lf) {
            return (range.lowerBound, range.upperBound)
        }
        return nil
    }

    private nonisolated static func parseHeaders(_ data: Data) -> Headers {
        // RFC 2047 encoded words are ASCII, while modern SMTPUTF8 messages may
        // contain raw UTF-8 headers. Prefer valid UTF-8, then fall back to the
        // byte-preserving Latin-1 view needed for legacy messages.
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let physicalLines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        var unfolded: [String] = []
        for lineSlice in physicalLines {
            let line = String(lineSlice)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " "
                    + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }

        var headers = Headers()
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !name.isEmpty else { continue }
            let valueStart = line.index(after: colon)
            let value = line[valueStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers.values[name, default: []].append(value)
        }
        return headers
    }

    private nonisolated static func bodyCandidates(
        in entity: Entity,
        depth: Int
    ) -> [BodyCandidate] {
        guard depth < 12, !isAttachment(entity.headers) else { return [] }

        let contentType = parsedHeaderValue(
            entity.headers.first("content-type") ?? "text/plain; charset=us-ascii"
        )
        let mediaType = contentType.value.lowercased()

        if mediaType.hasPrefix("multipart/"),
           let boundary = contentType.parameters["boundary"],
           !boundary.isEmpty {
            var found: [BodyCandidate] = []
            for part in multipartParts(entity.body, boundary: boundary).prefix(128) {
                found.append(contentsOf: bodyCandidates(in: parseEntity(part), depth: depth + 1))
            }
            return found
        }

        if mediaType == "message/rfc822" {
            let decoded = transferDecoded(
                entity.body,
                encoding: entity.headers.first("content-transfer-encoding")
            )
            return bodyCandidates(in: parseEntity(decoded), depth: depth + 1)
        }

        guard mediaType.hasPrefix("text/") else { return [] }
        let decoded = transferDecoded(
            entity.body,
            encoding: entity.headers.first("content-transfer-encoding")
        )
        guard !decoded.isEmpty else { return [] }

        let charset = contentType.parameters["charset"] ?? "us-ascii"
        var text = decodeText(decoded, charset: charset)
        if mediaType == "text/plain", contentType.parameters["format"]?.lowercased() == "flowed" {
            text = decodeFormatFlowed(
                text,
                deleteSpace: contentType.parameters["delsp"]?.lowercased() == "yes"
            )
        }
        text = normaliseNewlines(text)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !text.isEmpty else { return [] }

        let isHTML = mediaType == "text/html"
        let rank = mediaType == "text/plain" ? 0 : (isHTML ? 1 : 2)
        return [BodyCandidate(text: text, isHTML: isHTML, rank: rank)]
    }

    private nonisolated static func isAttachment(_ headers: Headers) -> Bool {
        if let dispositionRaw = headers.first("content-disposition") {
            let disposition = parsedHeaderValue(dispositionRaw)
            if disposition.value.caseInsensitiveCompare("attachment") == .orderedSame {
                return true
            }
            if disposition.parameters["filename"] != nil
                || disposition.parameters["filename*"] != nil {
                return true
            }
        }
        if let typeRaw = headers.first("content-type") {
            let type = parsedHeaderValue(typeRaw)
            if type.parameters["name"] != nil || type.parameters["name*"] != nil {
                return true
            }
        }
        return false
    }

    private nonisolated static func multipartParts(_ data: Data, boundary: String) -> [Data] {
        guard !boundary.isEmpty,
              let raw = String(data: data, encoding: .isoLatin1) else { return [] }
        let marker = "--\(boundary)"
        let chunks = raw.components(separatedBy: marker)
        guard chunks.count > 1 else { return [] }

        var parts: [Data] = []
        for chunk in chunks.dropFirst() {
            var segment = chunk
            if segment.hasPrefix("--") { break } // closing boundary
            while segment.hasPrefix("\r") || segment.hasPrefix("\n") {
                segment.removeFirst()
            }
            while segment.hasSuffix("\r") || segment.hasSuffix("\n") {
                segment.removeLast()
            }
            guard !segment.isEmpty, let bytes = segment.data(using: .isoLatin1) else { continue }
            parts.append(bytes)
        }
        return parts
    }

    // MARK: - Header decoding

    private nonisolated static func parsedHeaderValue(_ raw: String) -> HeaderValue {
        let pieces = splitHeaderParameters(raw)
        let value = pieces.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var value = piece[piece.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if !key.isEmpty { parameters[key] = value }
        }
        return HeaderValue(value: value, parameters: parameters)
    }

    private nonisolated static func splitHeaderParameters(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == ";", !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces
    }

    private nonisolated static func decodedHeader(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let pattern = #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let source = raw as NSString
        let matches = regex.matches(
            in: raw,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var output = ""
        var cursor = 0
        var previousWasEncodedWord = false
        for match in matches where match.numberOfRanges == 4 {
            let gapRange = NSRange(location: cursor, length: match.range.location - cursor)
            let gap = source.substring(with: gapRange)
            if !(previousWasEncodedWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                output += gap
            }

            let charset = source.substring(with: match.range(at: 1))
            let mode = source.substring(with: match.range(at: 2)).lowercased()
            let encoded = source.substring(with: match.range(at: 3))
            if let decoded = decodeEncodedWord(encoded, mode: mode, charset: charset) {
                output += decoded
            } else {
                output += source.substring(with: match.range)
            }
            cursor = NSMaxRange(match.range)
            previousWasEncodedWord = true
        }
        if cursor < source.length {
            output += source.substring(from: cursor)
        }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private nonisolated static func decodeEncodedWord(
        _ encoded: String,
        mode: String,
        charset: String
    ) -> String? {
        let data: Data?
        if mode == "b" {
            data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        } else {
            let q = encoded.replacingOccurrences(of: "_", with: " ")
            data = quotedPrintableDecoded(Data(q.utf8))
        }
        guard let data else { return nil }
        return decodeText(data, charset: charset)
    }

    // MARK: - Body decoding

    private nonisolated static func transferDecoded(_ data: Data, encoding raw: String?) -> Data {
        let encoding = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "7bit"
        switch encoding {
        case "base64":
            let source = String(data: data, encoding: .isoLatin1)
                ?? String(decoding: data, as: UTF8.self)
            return Data(base64Encoded: source, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return quotedPrintableDecoded(data)
        default:
            return data
        }
    }

    private nonisolated static func quotedPrintableDecoded(_ data: Data) -> Data {
        let bytes = Array(data)
        var result = Data()
        result.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x3D else { // "="
                result.append(bytes[index])
                index += 1
                continue
            }

            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2 // soft LF line break
                continue
            }
            if index + 2 < bytes.count,
               bytes[index + 1] == 0x0D,
               bytes[index + 2] == 0x0A {
                index += 3 // soft CRLF line break
                continue
            }
            if index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]),
               let low = hexValue(bytes[index + 2]) {
                result.append((high << 4) | low)
                index += 3
                continue
            }

            result.append(bytes[index])
            index += 1
        }
        return result
    }

    private nonisolated static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private nonisolated static func decodeText(_ data: Data, charset raw: String) -> String {
        let charset = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        let encoding: String.Encoding?
        switch charset {
        case "utf-8", "utf8":
            encoding = .utf8
        case "us-ascii", "ascii":
            encoding = .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            encoding = .isoLatin1
        case "iso-8859-2", "iso8859-2", "latin2", "latin-2":
            encoding = .isoLatin2
        case "windows-1252", "cp1252", "x-cp1252":
            encoding = .windowsCP1252
        case "macintosh", "macroman", "mac-roman", "x-mac-roman":
            encoding = .macOSRoman
        case "utf-16", "utf16":
            encoding = .utf16
        case "utf-16le", "utf16le":
            encoding = .utf16LittleEndian
        case "utf-16be", "utf16be":
            encoding = .utf16BigEndian
        case "utf-32", "utf32":
            encoding = .utf32
        case "utf-32le", "utf32le":
            encoding = .utf32LittleEndian
        case "utf-32be", "utf32be":
            encoding = .utf32BigEndian
        case "shift-jis", "shift_jis", "sjis", "windows-31j":
            encoding = .shiftJIS
        case "euc-jp", "eucjp":
            encoding = .japaneseEUC
        default:
            encoding = nil
        }

        if let encoding, let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func normaliseNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// RFC 3676 flowed text: lines ending in a space continue on the next line.
    /// Quote-depth changes and signature separators remain hard boundaries.
    private nonisolated static func decodeFormatFlowed(
        _ text: String,
        deleteSpace: Bool
    ) -> String {
        let lines = normaliseNewlines(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        var pending: String?
        var pendingQuoteDepth = 0

        for rawLine in lines {
            // Space stuffing protects lines beginning with "From ", ">", or a space.
            var line = rawLine
            if line.hasPrefix(" ") { line.removeFirst() }
            let quoteDepth = line.prefix { $0 == ">" }.count
            let isSignature = line == "-- "
            let isFlowed = line.hasSuffix(" ") && !isSignature

            if let current = pending, quoteDepth == pendingQuoteDepth {
                let continuation = String(line.dropFirst(quoteDepth))
                pending = current + continuation
            } else {
                if let current = pending { output.append(current) }
                pending = line
                pendingQuoteDepth = quoteDepth
            }

            if isFlowed {
                if deleteSpace, pending?.hasSuffix(" ") == true { pending?.removeLast() }
            } else if let current = pending {
                output.append(current)
                pending = nil
            }
        }
        if let pending { output.append(pending) }
        return output.joined(separator: "\n")
    }
}
