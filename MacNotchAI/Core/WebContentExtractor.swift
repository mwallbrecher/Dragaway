import Foundation
import WebKit

/// Model-ready text distilled from an HTTP(S) page. Website extraction is deliberately
/// separate from email HTML: only explicit `.webURL` / `.webloc` drops enter this file,
/// so rendering a website can never wake tracking resources embedded in an `.eml`.
struct WebPageContent: Sendable {
    enum Strategy: String, Sendable {
        case reader
        case semantic
        case body
    }

    let title: String?
    let byline: String?
    let siteName: String?
    let publishedTime: String?
    let excerpt: String?
    let text: String
    let strategy: Strategy
    let wasTruncated: Bool

    var formattedMetadata: [String] {
        var lines: [String] = []
        if let title, !title.isEmpty               { lines.append(title) }
        if let byline, !byline.isEmpty             { lines.append("By: \(byline)") }
        if let siteName, !siteName.isEmpty         { lines.append("Site: \(siteName)") }
        if let publishedTime, !publishedTime.isEmpty {
            lines.append("Published: \(publishedTime)")
        }
        return lines
    }

    var isMinimallyReadable: Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard text.count >= 80, words >= 12 else { return false }
        let lower = text.lowercased()
        let obstructionOnly = words < 35 && [
            "enable javascript", "javascript is disabled", "sign in to continue",
            "accept cookies", "access denied", "verify you are human",
        ].contains(where: lower.contains)
        return !obstructionOnly
    }

    /// Substantial server-rendered article text does not need to execute the page's
    /// JavaScript. Short reader hits still get compared with a rendered snapshot:
    /// they are often only a teaser or an SPA shell rather than the full article.
    var canSkipRenderedFallback: Bool {
        guard strategy == .reader else { return false }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return text.count >= 4_000 && words >= 500
    }

    var qualityScore: Int {
        let length = text.count
        let strategyBonus: Int
        switch strategy {
        // Strategy is only a tie-breaker. It must never make a short reader
        // fragment beat thousands of characters from the rendered document.
        case .reader:   strategyBonus = min(1_200, length / 5)
        case .semantic: strategyBonus = min(400, length / 10)
        case .body:     strategyBonus = 0
        }
        return strategyBonus + length + (title == nil ? 0 : 100)
    }
}

/// File-scoped preparation registry for materialized web drops.
///
/// The TXT is returned to the UI immediately. Extraction continues in the background,
/// while `buildMultiFileContent` awaits only tasks matching the exact staged file paths.
/// This avoids the fast-click race without coupling web work to a view-model session:
/// closing the UI can safely leave the bounded enrichment running for session history.
@MainActor
enum WebDropPreparation {
    private final class Destination {
        var file: URL

        init(file: URL) {
            self.file = file.standardizedFileURL
        }

        var path: String { file.standardizedFileURL.path }
    }

    private struct Entry {
        let destination: Destination
        let task: Task<Void, Never>
    }

    private static var pending: [String: Entry] = [:]

    static func start(file: URL, link: URL) {
        let destination = Destination(file: file)
        let initialPath = destination.path
        pending[initialPath]?.task.cancel()

        let task = Task(priority: .userInitiated) { @MainActor in
            defer { removeIfCurrent(destination) }

            guard let page = await WebContentExtractor.extract(from: link),
                  !Task.isCancelled,
                  pending[destination.path]?.destination === destination
            else { return }

            var header = page.formattedMetadata
            if header.isEmpty { header.append(link.absoluteString) }
            header.append("URL: \(link.absoluteString)")
            var content = header.joined(separator: "\n") + "\n\n" + page.text
            if page.wasTruncated {
                content += "\n\n[Website text truncated after 100,000 characters.]"
            }
            let target = destination.file

            guard pending[destination.path]?.destination === destination,
                  (try? content.write(to: target, atomically: true, encoding: .utf8)) != nil,
                  pending[destination.path]?.destination === destination
            else { return }

            // Atomic replacement may create a new inode and lose the presentation xattr.
            FilePresentation.markAsWebDrop(target)

            // Ordinarily the first extraction is waiting on this exact task. Keep the
            // defensive invalidation for a restored/older session that already cached
            // the URL-only placeholder before this process learned about the task.
            let vm = OverlayViewModel.shared
            if vm.sessionFileURLs.contains(where: {
                $0.standardizedFileURL.path == destination.path
            }) {
                vm.baseContext = nil
            }
        }

        pending[initialPath] = Entry(destination: destination, task: task)
    }

    /// Keep a pending extraction attached when a file utility renames or moves the
    /// materialized placeholder. The task reads its destination only after awaits,
    /// so its atomic write follows the new path instead of recreating the old file.
    static func remap(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        let newFile = new.standardizedFileURL
        let newPath = newFile.path
        guard oldPath != newPath,
              let entry = pending.removeValue(forKey: oldPath)
        else { return }

        if let displaced = pending[newPath],
           displaced.destination !== entry.destination {
            displaced.task.cancel()
        }
        entry.destination.file = newFile
        pending[newPath] = entry
    }

    private static func removeIfCurrent(_ destination: Destination) {
        let path = destination.path
        if pending[path]?.destination === destination {
            pending[path] = nil
        }
    }

    /// Snapshot before awaiting. The tasks are already running concurrently; awaiting
    /// their values in sequence does not serialize the network/render work.
    static func waitForPending(files: [URL]) async {
        var seen: Set<String> = []
        let tasks = files.compactMap { url -> Task<Void, Never>? in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return pending[path]?.task
        }
        for task in tasks { await task.value }
    }
}

// MARK: - Hybrid website extractor

/// Two-stage extraction with no paid service:
/// 1. fetch HTML through an ephemeral URLSession, build a resource-free DOM, run the
///    bundled Mozilla Readability;
/// 2. only when that result is thin, render the live URL in an invisible, ephemeral
///    WKWebView and retry after the DOM settles.
@MainActor
enum WebContentExtractor {
    fileprivate nonisolated static let maximumDownloadBytes = 3_000_000
    private nonisolated static let maximumStoredCharacters = 100_000
    private static let cachedReadabilityScript: String = {
        let resource = Bundle.main.url(
            forResource: "Readability", withExtension: "js", subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: "Readability", withExtension: "js")
        guard let resource,
              let source = try? String(contentsOf: resource, encoding: .utf8)
        else { return "" }
        return source
    }()

    private struct FetchedDocument: Sendable {
        let html: String
        let finalURL: URL
        let isPlainText: Bool
        let mayRequireRendering: Bool
    }

    private struct ReaderPayload: Decodable {
        let title: String?
        let byline: String?
        let siteName: String?
        let publishedTime: String?
        let excerpt: String?
        let readerText: String?
        let semanticText: String?
        let bodyText: String?
    }

    static func extract(from link: URL) async -> WebPageContent? {
        guard ["http", "https"].contains(link.scheme?.lowercased() ?? "") else {
            return nil
        }

        let fetched = await fetchDocument(from: link)
        var staticCandidate: WebPageContent?
        var liveURL = link

        if let fetched {
            liveURL = fetched.finalURL
            if fetched.isPlainText {
                staticCandidate = candidate(
                    title: nil,
                    text: fetched.html,
                    strategy: .body
                )
            } else {
                let localRules = await WebExtractionContentRules.ruleList(for: .local)
                // The HTML has also been stripped of active/resource-bearing markup,
                // so the local pass remains safe if WebKit cannot compile its rule list.
                let session = WebPageRenderSession(
                    input: .staticHTML(fetched.html, baseURL: fetched.finalURL),
                    contentRuleList: localRules,
                    readabilitySource: bundledReadabilityScript()
                )
                staticCandidate = await session.run(timeoutNanoseconds: 2_500_000_000)
            }
        }

        if fetched?.isPlainText == true {
            return staticCandidate?.isMinimallyReadable == true ? staticCandidate : nil
        }

        if let staticCandidate,
           staticCandidate.canSkipRenderedFallback
            || (fetched?.mayRequireRendering == false && staticCandidate.isMinimallyReadable) {
            return staticCandidate
        }

        // Rendering executes the website's own JavaScript. Never do that without the
        // resource blocker: failing closed is preferable to an unbounded hidden page.
        guard let liveRules = await WebExtractionContentRules.ruleList(for: .live) else {
            return staticCandidate?.isMinimallyReadable == true ? staticCandidate : nil
        }

        let liveSession = WebPageRenderSession(
            input: .liveURL(liveURL),
            contentRuleList: liveRules,
            readabilitySource: bundledReadabilityScript()
        )
        let liveCandidate = await liveSession.run(timeoutNanoseconds: 7_000_000_000)

        let candidates = [staticCandidate, liveCandidate].compactMap { $0 }
        let best = candidates.max(by: { $0.qualityScore < $1.qualityScore })
        return best?.isMinimallyReadable == true ? best : nil
    }

    private static func candidate(
        title: String?,
        byline: String? = nil,
        siteName: String? = nil,
        publishedTime: String? = nil,
        excerpt: String? = nil,
        text: String,
        strategy: WebPageContent.Strategy
    ) -> WebPageContent? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        let wasTruncated = normalized.count > maximumStoredCharacters
        return WebPageContent(
            title: cleanMetadata(title),
            byline: cleanMetadata(byline),
            siteName: cleanMetadata(siteName),
            publishedTime: cleanMetadata(publishedTime),
            excerpt: cleanMetadata(excerpt),
            text: String(normalized.prefix(maximumStoredCharacters)),
            strategy: strategy,
            wasTruncated: wasTruncated
        )
    }

    private static func candidate(from payload: ReaderPayload) -> WebPageContent? {
        let candidates = [
            (payload.readerText, WebPageContent.Strategy.reader),
            (payload.semanticText, WebPageContent.Strategy.semantic),
            (payload.bodyText, WebPageContent.Strategy.body),
        ]
        .compactMap { pair in
            candidate(
                title: payload.title,
                byline: payload.byline,
                siteName: payload.siteName,
                publishedTime: payload.publishedTime,
                excerpt: payload.excerpt,
                text: pair.0 ?? "",
                strategy: pair.1
            )
        }

        guard let longest = candidates.max(by: { $0.text.count < $1.text.count }) else {
            return nil
        }
        // Reader/main content wins when it retains most of the available text. If
        // either is only a small fragment, keep the richer body snapshot instead.
        // This filters page chrome without recreating the old fixed-bonus bug.
        if let reader = candidates.first(where: { $0.strategy == .reader }),
           reader.isMinimallyReadable,
           reader.text.count * 100 >= longest.text.count * 55 {
            return reader
        }
        if let semantic = candidates.first(where: { $0.strategy == .semantic }),
           semantic.isMinimallyReadable,
           semantic.text.count * 100 >= longest.text.count * 65 {
            return semantic
        }
        return longest
    }

    fileprivate static func decodePayload(_ json: String) -> WebPageContent? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReaderPayload.self, from: data)
        else { return nil }
        return candidate(from: payload)
    }

    private static func cleanMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(500))
    }

    private static func normalize(_ raw: String) -> String {
        let newlineNormalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        var lines: [String] = []
        var previousWasBlank = true
        for rawLine in newlineNormalized.components(separatedBy: "\n") {
            let line = rawLine
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !previousWasBlank { lines.append("") }
                previousWasBlank = true
            } else {
                lines.append(line)
                previousWasBlank = false
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch only the document response. Cookies/cache are memory-only, a Range request
    /// encourages cooperative servers to stop at the cap, and the stream is truncated
    /// before DOM construction if the server ignores that range.
    @concurrent private nonisolated static func fetchDocument(
        from link: URL
    ) async -> FetchedDocument? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpMaximumConnectionsPerHost = 2

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: link, timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 "
                + "Safari/605.1.15 Dragaway/1.1.4",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,text/plain;q=0.8,*/*;q=0.2",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("bytes=0-\(maximumDownloadBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("1", forHTTPHeaderField: "DNT")

        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              ["http", "https"].contains(finalURL.scheme?.lowercased() ?? "")
        else { return nil }

        var receivedData = Data()
        let advertised = max(0, http.expectedContentLength)
        receivedData.reserveCapacity(
            min(Int(min(advertised, Int64(maximumDownloadBytes))), maximumDownloadBytes)
        )
        do {
            for try await byte in bytes {
                // Stop consuming immediately even when a server ignores the Range
                // request or streams a chunked response with no Content-Length.
                guard receivedData.count < maximumDownloadBytes else { break }
                receivedData.append(byte)
            }
        } catch {
            return nil
        }
        guard !receivedData.isEmpty else { return nil }

        let mime = http.mimeType?.lowercased()
        let prefix = String(decoding: receivedData.prefix(1_024), as: UTF8.self).lowercased()
        let looksLikeHTML = prefix.contains("<!doctype html")
            || prefix.contains("<html")
            || prefix.contains("<head")
            || prefix.contains("<body")
        // Misconfigured servers sometimes label HTML as text/plain. A clear HTML
        // signature wins so those pages still receive DOM/Readability extraction.
        let isPlainText = mime == "text/plain" && !looksLikeHTML
        let isHTML = mime?.contains("html") == true
            || mime == "application/xhtml+xml"
            || looksLikeHTML
        guard isPlainText || isHTML else { return nil }

        guard let decoded = decode(receivedData, response: http) else { return nil }
        let withoutStructuredData = decoded.replacingOccurrences(
            of: #"(?is)<script\b(?=[^>]*\btype\s*=\s*([\"'])application/ld\+json\1)[^>]*>.*?</script\s*>"#,
            with: "",
            options: .regularExpression
        )
        let mayRequireRendering = !isPlainText && withoutStructuredData.range(
            of: #"(?i)<script\b"#,
            options: .regularExpression
        ) != nil
        // Plain text does not need a DOM. Keep only enough to populate the bounded
        // stored result plus its truncation signal before returning to MainActor.
        let prepared = isPlainText
            ? String(decoded.prefix(maximumStoredCharacters + 1))
            : sanitizeForLocalDOM(decoded)
        return FetchedDocument(
            html: prepared,
            finalURL: finalURL,
            isPlainText: isPlainText,
            mayRequireRendering: mayRequireRendering
        )
    }

    private nonisolated static func decode(_ data: Data, response: HTTPURLResponse) -> String? {
        if let charset = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let raw = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let value = String(data: data, encoding: String.Encoding(rawValue: raw)) {
                    return value
                }
            }
        }
        if let value = String(data: data, encoding: .utf8) { return value }
        // A response stopped exactly at the byte cap can split the final UTF-8
        // scalar. Trim at most that incomplete suffix before trying legacy encodings.
        for suffixLength in 1...3 where data.count > suffixLength {
            if let value = String(data: data.dropLast(suffixLength), encoding: .utf8) {
                return value
            }
        }
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Defense in depth for the local DOM pass. Page JavaScript is disabled there and
    /// the content-rule list blocks remote resources; this also removes active markup,
    /// refreshes and resource-bearing attributes before WebKit ever sees the string.
    private nonisolated static func sanitizeForLocalDOM(_ input: String) -> String {
        var html = input
        html = html.replacingOccurrences(
            of: #"(?is)<!--.*?(?:-->|$)"#,
            with: "",
            options: .regularExpression
        )
        for tag in ["script", "style", "iframe", "object", "svg", "canvas", "template"] {
            html = html.replacingOccurrences(
                of: #"(?is)<\#(tag)\b[^>]*>.*?(?:</\#(tag)\s*>|$)"#,
                with: "",
                options: .regularExpression
            )
        }
        html = html.replacingOccurrences(
            of: #"(?is)<(?:link|base|embed)\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"(?is)<meta\b[^>]*http-equiv\s*=\s*([\"']?)refresh\1[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"(?is)\s(?:src|srcset|poster|data-src|data-srcset|style|background|lowsrc|href|action|formaction|ping)\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"(?is)\son[a-z0-9_-]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression
        )
        return html
    }

    private static func bundledReadabilityScript() -> String {
        cachedReadabilityScript
    }
}

// MARK: - Content blockers

@MainActor
private enum WebExtractionContentRules {
    enum Kind: Hashable {
        case local
        case live

        var identifier: String {
            switch self {
            case .local: return "com.dragaway.web-extraction.local.v1"
            case .live:  return "com.dragaway.web-extraction.live.v2"
            }
        }

        var encodedRules: String {
            switch self {
            case .local:
                return """
                [{"trigger":{"url-filter":".*","resource-type":["script","style-sheet","image","font","media","svg-document","raw","popup"]},
                  "action":{"type":"block"}}]
                """
            case .live:
                return """
                [{"trigger":{"url-filter":".*","resource-type":["image","font","media","svg-document","popup"]},
                  "action":{"type":"block"}},
                 {"trigger":{"url-filter":".*","load-type":["third-party"],"resource-type":["script","style-sheet","raw"]},
                  "action":{"type":"block"}}]
                """
            }
        }
    }

    private static var cache: [Kind: WKContentRuleList] = [:]
    private static var continuations: [
        UUID: CheckedContinuation<WKContentRuleList?, Never>
    ] = [:]
    private static var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    static func ruleList(for kind: Kind) async -> WKContentRuleList? {
        if let cached = cache[kind] { return cached }
        return await withCheckedContinuation { continuation in
            let requestID = UUID()
            continuations[requestID] = continuation
            timeoutTasks[requestID] = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch { return }
                complete(requestID: requestID, kind: kind, list: nil)
            }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: kind.identifier,
                encodedContentRuleList: kind.encodedRules
            ) { list, _ in
                Task { @MainActor in
                    complete(requestID: requestID, kind: kind, list: list)
                }
            }
        }
    }

    private static func complete(
        requestID: UUID,
        kind: Kind,
        list: WKContentRuleList?
    ) {
        // A compile that completed after the caller's timeout is still useful for the
        // next drop, but the original continuation must be resumed exactly once.
        if let list { cache[kind] = list }
        guard let continuation = continuations.removeValue(forKey: requestID) else { return }
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(returning: list)
    }
}

// MARK: - One invisible WebKit render

@MainActor
private final class WebPageRenderSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Input {
        case staticHTML(String, baseURL: URL)
        case liveURL(URL)

        var allowsPageJavaScript: Bool {
            if case .liveURL = self { return true }
            return false
        }

        var needsDOMSettle: Bool { allowsPageJavaScript }
    }

    private enum RenderError: Error { case invalidJavaScriptResult }

    private let input: Input
    private let readabilitySource: String
    private let webView: WKWebView
    private var continuation: CheckedContinuation<WebPageContent?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private var didFinishInitialNavigation = false
    private var navigationDecisionCount = 0
    private var isFinished = false

    init(input: Input, contentRuleList: WKContentRuleList?, readabilitySource: String) {
        self.input = input
        self.readabilitySource = readabilitySource

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = input.allowsPageJavaScript
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        if let contentRuleList {
            configuration.userContentController.add(contentRuleList)
        }

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900),
            configuration: configuration
        )
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 "
            + "Safari/605.1.15 Dragaway/1.1.4"

        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func run(timeoutNanoseconds: UInt64) async -> WebPageContent? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if isFinished || Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch { return }
                    self?.finish(nil)
                }

                switch input {
                case .staticHTML(let html, let baseURL):
                    webView.loadHTMLString(html, baseURL: baseURL)
                case .liveURL(let url):
                    var request = URLRequest(url: url, timeoutInterval: 6)
                    request.setValue("1", forHTTPHeaderField: "DNT")
                    request.setValue(
                        "bytes=0-\(WebContentExtractor.maximumDownloadBytes - 1)",
                        forHTTPHeaderField: "Range"
                    )
                    request.setValue(
                        "text/html,application/xhtml+xml,*/*;q=0.2",
                        forHTTPHeaderField: "Accept"
                    )
                    webView.load(request)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        })
    }

    private func finish(_ result: WebPageContent?) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        extractionTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private func extractAfterNavigation() {
        guard extractionTask == nil, !isFinished else { return }
        extractionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if input.needsDOMSettle {
                try? await waitForDOMToSettle()
            }
            guard !Task.isCancelled, !isFinished else { return }
            do {
                let json = try await callClientJavaScript(readerScript)
                finish(WebContentExtractor.decodePayload(json))
            } catch {
                finish(nil)
            }
        }
    }

    private func waitForDOMToSettle() async throws {
        _ = try await callClientJavaScript(#"""
        return await new Promise(resolve => {
          let completed = false;
          const startedAt = performance.now();
          let lastMutationAt = startedAt;
          let pollTimer;
          const observer = new MutationObserver(() => {
            lastMutationAt = performance.now();
          });
          function done() {
            if (completed) return;
            completed = true;
            observer.disconnect();
            clearInterval(pollTimer);
            resolve("settled");
          }
          observer.observe(document.documentElement || document, {
            childList: true, subtree: true, characterData: true
          });
          pollTimer = setInterval(() => {
            const now = performance.now();
            const waitedLongEnough = now - startedAt >= 900;
            const isQuiet = now - lastMutationAt >= 350;
            if (waitedLongEnough && isQuiet) done();
          }, 100);
          setTimeout(done, 2200);
        });
        """#)
    }

    private var readerScript: String {
        #"""
        \#(readabilitySource)

        function dragawayClean(value) {
          return String(value || "")
            .replace(/\r\n?/g, "\n")
            .replace(/[\t\f\v\u00a0 ]+/g, " ")
            .replace(/ *\n */g, "\n")
            .replace(/\n{3,}/g, "\n\n")
            .trim();
        }

        function dragawayMeta(selector) {
          const node = document.querySelector(selector);
          return node
            ? (node.content || node.getAttribute("datetime") || node.textContent || "")
            : "";
        }

        function dragawayStructuredText(root) {
          if (!root) return "";
          const clone = root.cloneNode(true);
          clone.querySelectorAll("br").forEach(node => {
            node.replaceWith(document.createTextNode("\n"));
          });
          clone.querySelectorAll("li").forEach(node => {
            node.insertBefore(document.createTextNode("• "), node.firstChild);
            node.append(document.createTextNode("\n"));
          });
          clone.querySelectorAll(
            "p,div,section,article,main,header,h1,h2,h3,h4,h5,h6,blockquote,pre,tr,table,ul,ol"
          ).forEach(node => node.append(document.createTextNode("\n")));
          clone.querySelectorAll("td,th").forEach(node => {
            node.append(document.createTextNode("\t"));
          });
          return dragawayClean(clone.textContent);
        }

        let article = null;
        try {
          if (typeof Readability === "function") {
            article = new Readability(document.cloneNode(true), {
              charThreshold: 180,
              maxElemsToParse: 50000
            }).parse();
          }
        } catch (_) {}

        let readerRoot = null;
        if (article && article.content) {
          readerRoot = document.createElement("div");
          readerRoot.innerHTML = article.content;
        }
        const readerText = dragawayStructuredText(readerRoot);
        const semanticNodes = Array.from(
          document.querySelectorAll("main, article, [role='main']")
        ).sort((a, b) => (b.innerText || "").length - (a.innerText || "").length);
        const semanticText = dragawayClean(semanticNodes[0] && semanticNodes[0].innerText);
        const bodyText = dragawayClean(document.body && document.body.innerText);

        const title = dragawayClean(
          (article && article.title)
          || dragawayMeta("meta[property='og:title']")
          || document.title
        );

        return JSON.stringify({
          title: title || null,
          byline: dragawayClean(
            (article && article.byline)
            || dragawayMeta("meta[name='author']")
          ) || null,
          siteName: dragawayClean(
            (article && article.siteName)
            || dragawayMeta("meta[property='og:site_name']")
          ) || null,
          publishedTime: dragawayClean(
            (article && article.publishedTime)
            || dragawayMeta("meta[property='article:published_time']")
            || dragawayMeta("time[datetime]")
          ) || null,
          excerpt: dragawayClean(
            (article && article.excerpt)
            || dragawayMeta("meta[name='description']")
            || dragawayMeta("meta[property='og:description']")
          ) || null,
          readerText: readerText.slice(0, 120000),
          semanticText: semanticText.slice(0, 120000),
          bodyText: bodyText.slice(0, 120000)
        });
        """#
    }

    private func callClientJavaScript(_ source: String) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            source,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let string = value as? String else {
            throw RenderError.invalidJavaScriptResult
        }
        return string
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = input.allowsPageJavaScript

        guard navigationAction.targetFrame != nil,
              navigationAction.targetFrame?.isMainFrame == true,
              !navigationAction.shouldPerformDownload,
              !didFinishInitialNavigation,
              navigationDecisionCount < 8,
              let scheme = navigationAction.request.url?.scheme?.lowercased()
        else {
            decisionHandler(.cancel, preferences)
            return
        }

        let allowedSchemes: Set<String>
        switch input {
        case .staticHTML:
            allowedSchemes = ["about", "data", "file", "http", "https"]
        case .liveURL:
            allowedSchemes = ["http", "https"]
        }
        guard allowedSchemes.contains(scheme) else {
            decisionHandler(.cancel, preferences)
            return
        }

        navigationDecisionCount += 1
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        let isMainFrame = navigationResponse.isForMainFrame
        let statusIsAllowed = !isMainFrame
            || (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } != false
        let sizeIsAllowed = !isMainFrame
            || response.expectedContentLength < 0
            || response.expectedContentLength <= Int64(WebContentExtractor.maximumDownloadBytes)
        let mimeIsAllowed = !isMainFrame
            || response.mimeType?.lowercased().contains("html") == true
            || response.mimeType == nil
        guard navigationResponse.canShowMIMEType,
              statusIsAllowed,
              sizeIsAllowed,
              mimeIsAllowed
        else {
            decisionHandler(.cancel)
            finish(nil)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinishInitialNavigation else { return }
        didFinishInitialNavigation = true
        extractAfterNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: WKUIDelegate — never present page-controlled UI

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) { completionHandler() }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) { completionHandler(false) }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) { completionHandler(nil) }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) { decisionHandler(.deny) }
}
