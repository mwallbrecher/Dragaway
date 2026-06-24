import Foundation
import NaturalLanguage

struct FileInspector {
    /// Content-aware suggestions: start from the fixed extension map, then reorder/filter using
    /// cheap LOCAL signals (`FileSignals.peek` — bounded text peek, no network/LLM). Falls back to
    /// the plain `baseActions` list when there's nothing to read (media/unsupported, or peek fails).
    static func suggestedActions(for url: URL) -> [AIAction] {
        let base = baseActions(for: url)
        guard !base.isEmpty else { return base }
        return reorder(base, using: cachedPeek(url), isProse: isProseFile(url))
    }

    // MARK: - Peek cache
    //
    // `suggestedActions` is recomputed on every SwiftUI body render (the result-stage Suggested
    // rail calls it inside a `ForEach`), so the bounded content peek is memoised by path + mtime.
    // All callers are @MainActor (stage writes + SwiftUI body on main), so a plain dictionary is
    // safe — no locking needed.
    private static var peekCache: [String: FileSignals.Signals] = [:]

    private static func cachedPeek(_ url: URL) -> FileSignals.Signals {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(mtime)"
        if let hit = peekCache[key] { return hit }
        let signals = FileSignals.peek(url)
        if peekCache.count > 64 { peekCache.removeAll() }   // crude unbounded-growth guard
        peekCache[key] = signals
        return signals
    }

    /// The fixed extension → action mapping (no content inspection).
    static func baseActions(for url: URL) -> [AIAction] {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return [.summariseBullets, .extractKeyDates, .extractKeyPoints, .translateGerman, .rephraseFormal]
        case "txt", "md", "rtf":
            return [.summariseBullets, .summariseShort, .rephraseFormal, .rephraseCasual, .translateGerman]
        case "docx", "doc", "pages":
            return [.summariseBullets, .extractKeyPoints, .rephraseFormal, .translateGerman]
        case "swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "rb", "java", "kt", "cpp", "c", "cs":
            return [.explainCode, .findBugs, .addDocstring, .refactor]
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff":
            return [.describeImage, .extractTextFromImage, .generateAltText]
        case "csv":
            return [.summariseBullets, .extractKeyPoints]
        case "json", "xml", "yaml", "yml":
            return [.explainCode, .summariseBullets]
        case _ where isMediaFile(url):
            // Video / audio: no hosted-AI actions (text & vision models can't read raw
            // media), BUT still DROPPABLE — the user can open them in a favorite app
            // (Pillar 1) or run a local file utility (Pillar 2). See isUnsupportedFileType.
            return []
        case "zip", "rar", "7z", "tar", "gz",
             "dmg", "pkg", "exe":
            return []   // truly unsupported — caller routes to the error stage
        default:
            return [.summariseBullets, .summariseShort, .extractKeyPoints]
        }
    }

    /// Returns the union of suggested actions for all given URLs, preserving the order from the
    /// first URL and appending actions from subsequent URLs that aren't already present, then
    /// reordering by the PRIMARY (first) file's content signals — bounding the multi-file peek
    /// cost to a single read.
    static func suggestedActions(forAll urls: [URL]) -> [AIAction] {
        guard let primary = urls.first else { return [] }
        let union = baseActions(forAll: urls)
        guard !union.isEmpty else { return union }
        return reorder(union, using: cachedPeek(primary), isProse: isProseFile(primary))
    }

    /// The instant (no-peek) union of base actions across `urls`, preserving first-URL
    /// order. Used to show the chips card immediately; the content-aware reorder is
    /// applied afterwards via `peekSignals` + `smartReorder` off the main thread.
    static func baseActions(forAll urls: [URL]) -> [AIAction] {
        var seen = Set<AIAction>()
        var union: [AIAction] = []
        for url in urls {
            for action in baseActions(for: url) where seen.insert(action).inserted {
                union.append(action)
            }
        }
        return union
    }

    /// Off-main-safe content peek (no cache touch — the cache is main-actor only).
    /// Pair with `smartReorder` back on the main actor.
    nonisolated static func peekSignals(_ url: URL) -> FileSignals.Signals {
        FileSignals.peek(url)
    }

    /// Reorder a precomputed base list using already-peeked signals (cheap, no IO).
    static func smartReorder(_ base: [AIAction],
                             primary: URL,
                             signals: FileSignals.Signals) -> [AIAction] {
        guard !base.isEmpty else { return base }
        return reorder(base, using: signals, isProse: isProseFile(primary))
    }

    // MARK: - Heuristic reorder

    /// Stable reorder + light filter of `base` using local content `signals`. Rules are ordered so
    /// the highest-priority signal runs LAST (each `moveToFront`/insert wins the #0 slot):
    /// length → dates/money → translate-to-English. Never returns empty; deduped; capped ≤ 6.
    static func reorder(_ base: [AIAction],
                        using s: FileSignals.Signals,
                        isProse: Bool) -> [AIAction] {
        var actions = base

        // Prose carrying a ``` code fence → make "Explain This Code" available.
        if isProse, s.hasCodeFences, !actions.contains(.explainCode) {
            actions.append(.explainCode)
        }

        // Length tuning (prose only).
        if isProse {
            if s.isShort {
                actions.removeAll { $0 == .summariseBullets }   // too little to bullet
            } else if s.isLong {
                moveToFront(.summariseBullets, in: &actions)
                moveToFront(.summariseShort,  in: &actions)     // ends up first
            }
        }

        // Dates / money heavy → bubble extraction up (no-ops if those actions aren't present).
        if s.hasManyDates || s.isMonetary {
            moveToFront(.extractKeyPoints, in: &actions)
            moveToFront(.extractKeyDates,  in: &actions)        // ends up first
        }

        // Non-English prose → lead with "Translate to English" and drop the to-<source> target.
        if isProse, let lang = s.dominantLanguage, lang != .english {
            if let sameTarget = translateAction(forSource: lang) {
                actions.removeAll { $0 == sameTarget }
            }
            actions.removeAll { $0 == .translateEnglish }
            actions.insert(.translateEnglish, at: 0)
        }

        var seen = Set<AIAction>()
        let deduped = actions.filter { seen.insert($0).inserted }
        let capped = Array(deduped.prefix(6))
        return capped.isEmpty ? base : capped
    }

    private static func moveToFront(_ action: AIAction, in actions: inout [AIAction]) {
        guard let idx = actions.firstIndex(of: action), idx != 0 else { return }
        actions.remove(at: idx)
        actions.insert(action, at: 0)
    }

    /// The "Translate to X" action whose target equals `lang` (so it can be dropped when we're
    /// instead offering "Translate to English"). Only the three targets we ship.
    private static func translateAction(forSource lang: NLLanguage) -> AIAction? {
        switch lang {
        case .german:  return .translateGerman
        case .french:  return .translateFrench
        case .spanish: return .translateSpanish
        default:       return nil
        }
    }

    /// Natural-language documents where translate / summarise / rephrase / length-tuning apply.
    /// Deliberately excludes code & structured data (csv/json/xml) and media/images.
    private static func isProseFile(_ url: URL) -> Bool {
        ["pdf", "txt", "md", "markdown", "rtf", "docx", "doc", "pages"]
            .contains(url.pathExtension.lowercased())
    }

    /// Returns true for file types AI Drop cannot process at all (archives, installers).
    /// Drop handlers use this to route directly to the error stage.
    ///
    /// NOTE: video/audio are NOT unsupported — they have no AI actions but ARE droppable
    /// (Open-in + file utilities), so they are exempted here and land in the chips stage.
    static func isUnsupportedFileType(_ url: URL) -> Bool {
        if isMediaFile(url) { return false }
        return baseActions(for: url).isEmpty   // emptiness only — skip the content peek
    }

    static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    static let videoExtensions = ["mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm"]
    static let audioExtensions = ["mp3", "aac", "wav", "flac", "ogg", "m4a", "aiff", "aif"]

    static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Plain-text / code / data extensions whose CONTENTS are line-oriented UTF-8 text.
    /// Deliberately NOT pdf/docx/rtf (those are containers, not plain text) — the text
    /// line tools (sort/dedupe/count/base64) only make sense on real text. `b64`/`base64`
    /// are included so a dropped Base64 file offers Decode.
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "ndjson", "jsonl",
        "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "env",
        "log", "html", "htm", "css", "scss", "sass", "less",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs",
        "java", "kt", "kts", "gradle", "c", "h", "cpp", "cc", "hpp", "hh", "cs",
        "m", "mm", "php", "sh", "bash", "zsh", "fish", "sql", "r", "lua", "pl",
        "pm", "dart", "scala", "clj", "ex", "exs", "vue", "svelte", "tex",
        "srt", "vtt", "gitignore", "b64", "base64"
    ]

    /// True for line-oriented UTF-8 text/code/data files (gates the text-tool cluster).
    static func isTextFile(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    /// Video or audio. These carry no hosted-AI path (the chips stage hides the prompt
    /// field + AI tabs for them) but are droppable for Open-in / file utilities.
    static func isMediaFile(_ url: URL) -> Bool {
        isVideoFile(url) || isAudioFile(url)
    }

    static func requiresVision(_ url: URL) -> Bool {
        return isImageFile(url)
    }

    /// The favorite-apps category a dropped file belongs to. `.text` is the catch-all
    /// for everything droppable that isn't image/video/audio (PDF, code, json, docx, …).
    static func category(for url: URL) -> FileCategory {
        if isImageFile(url) { return .image }
        if isVideoFile(url) { return .video }
        if isAudioFile(url) { return .audio }
        return .text
    }
}

/// Coarse file class used to scope the user's favorite apps (Settings → Favorite Tools).
/// Order here drives the order of the Settings tabs.
enum FileCategory: String, CaseIterable, Codable {
    case image, video, audio, text

    /// Tab label shown in Settings.
    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .text:  return "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .text:  return "doc.text"
        }
    }
}
