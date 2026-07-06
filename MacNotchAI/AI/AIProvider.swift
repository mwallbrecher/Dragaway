import Foundation
import SwiftUI

/// One model-facing conversation turn. `role` is "system" | "user" | "assistant".
/// The orchestrator (OverlayView.sendTurn) builds the full array; providers just
/// serialise it to their wire format.
struct ChatTurn {
    let role: String
    let content: String
    /// Large, STABLE content (the extracted document) carried separately from the
    /// turn's instruction so prompt caching can target it. It lives on the FIRST user
    /// turn only and is byte-identical on every follow-up, so it forms a cacheable
    /// leading prefix (doc §6). Providers with explicit caching (Anthropic) mark it
    /// with `cache_control`; the rest fold it back into the text via `flattenedContent`,
    /// which keeps OpenAI/Gemini *automatic* prefix caching working unchanged.
    var cacheableDocument: String? = nil
}

extension ChatTurn {
    /// The turn's text with the cacheable document folded in, byte-identical to the
    /// pre-caching layout (`instruction` + the document framing). Used by every
    /// provider WITHOUT explicit prompt caching.
    var flattenedContent: String {
        guard let doc = cacheableDocument, !doc.isEmpty else { return content }
        return content + "\n\n--- Document(s) ---\n" + doc
    }
}

protocol AIProvider {
    var name: String { get }
    var isAvailable: Bool { get }
    /// Multi-turn completion. `messages` is the WHOLE conversation (system turn
    /// first); the document content lives in the first user turn. `imageURL`, when
    /// set, is attached to the FIRST user turn for vision models. `plan` carries the
    /// deterministic routing decision (`maxOutputTokens` runaway guard + `tier`); every
    /// provider honours the ceiling, and the hosted Worker also uses `tier` to pick the
    /// model. See docs/HOW_LLM_IS_CHOSEN.md §4–§5.
    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String

    /// Streaming variant: `onDelta` fires (on the main actor) for every text fragment
    /// as it arrives; the full reply is returned at the end. Providers without a
    /// streaming implementation fall back to `reply` (single delta-less completion),
    /// so callers can use this unconditionally.
    func replyStream(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
                     onDelta: @escaping (String) -> Void) async throws -> String
}

extension AIProvider {
    /// Default: no streaming — one shot via `reply`, no deltas.
    func replyStream(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
                     onDelta: @escaping (String) -> Void) async throws -> String {
        try await reply(messages: messages, imageURL: imageURL, plan: plan)
    }
}

// MARK: - Shared SSE streaming (OpenAI-compatible providers)

/// POST `request` (whose body must include `"stream": true`) and consume the
/// OpenAI-compatible SSE stream (`data: {...}` lines, `choices[0].delta.content`,
/// terminated by `data: [DONE]`). Used by Groq, OpenAI, Gemini (OpenAI-compat
/// endpoint), and Ollama. Returns the concatenated full text.
func openAICompatSSE(request: URLRequest,
                     onDelta: @escaping (String) -> Void) async throws -> String {
    var request = request
    // CRITICAL for visible streaming: URLSession advertises gzip by default, and its
    // transparent decompression BUFFERS a compressed event stream until the response
    // completes — every delta then arrives in one burst at the end (looks exactly like
    // a non-streaming reply). Force identity so bytes flow through as they're sent.
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        var data = Data()
        for try await b in bytes { data.append(b) }     // error bodies are small
        throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
    }

    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    var full = ""
    var deltas = 0
    let t0 = Date()
    var firstDeltaMs = -1
    for try await line in bytes.lines {
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { break }
        guard let d = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: d),
              let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty
        else { continue }
        deltas += 1
        if firstDeltaMs < 0 { firstDeltaMs = Int(Date().timeIntervalSince(t0) * 1000) }
        full += delta
        onDelta(delta)
    }
#if DEBUG
    // Cadence check (Console filter: "[stream]"): many deltas spread over the total
    // means live streaming; deltas ≈ total-time-bunched means something buffered.
    NSLog("[stream] deltas=%d first=%dms total=%dms chars=%d",
          deltas, firstDeltaMs, Int(Date().timeIntervalSince(t0) * 1000), full.count)
#endif
    guard !full.isEmpty else { throw AIError.apiError("Empty response") }
    return full
}

// MARK: - Shared wire-format helpers (OpenAI-compatible providers)

/// MIME guess for a base64 `data:` URL.
func aiImageMime(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "gif":         return "image/gif"
    case "webp":        return "image/webp"
    case "heic":        return "image/heic"
    default:            return "image/png"
    }
}

/// Build an OpenAI-compatible `messages` array from chat turns. When `attachImage`
/// is true and `imageURL` is a readable image, it is inlined (base64 data URL) into
/// the FIRST user turn. Text-only models (Groq/Ollama) pass `attachImage: false` so
/// an image session degrades to text instead of erroring.
func openAICompatMessages(_ turns: [ChatTurn], imageURL: URL?, attachImage: Bool) -> [[String: Any]] {
    var imageUsed = false
    return turns.map { turn -> [String: Any] in
        if attachImage, turn.role == "user", !imageUsed,
           let imageURL, FileInspector.isImageFile(imageURL),
           let data = try? Data(contentsOf: imageURL) {
            imageUsed = true
            let b64 = data.base64EncodedString()
            let mime = aiImageMime(for: imageURL)
            return ["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(b64)"]],
                ["type": "text", "text": turn.flattenedContent]
            ]]
        }
        return ["role": turn.role, "content": turn.flattenedContent]
    }
}

enum AIProviderType: String, CaseIterable {
    case groq       = "Groq (Free)"
    case gemini     = "Gemini (Google)"
    case openai     = "OpenAI (GPT-4o)"
    case anthropic  = "Anthropic (Claude)"
    case ollama     = "Ollama (Local, Free)"
}

// MARK: - Display metadata (used by provider picker in Onboarding + Settings)

extension AIProviderType {

    /// Short, friendly name shown as the row title.
    var displayName: String {
        switch self {
        case .groq:      return "Groq"
        case .gemini:    return "Gemini"
        case .anthropic: return "Claude"
        case .openai:    return "ChatGPT"
        case .ollama:    return "Ollama"
        }
    }

    /// Model badge shown next to the provider name in the picker row.
    var modelLabel: String {
        switch self {
        case .groq:      return "Llama 3.1 8B"
        case .gemini:    return "Gemini 2.5 Flash"
        case .anthropic: return "Haiku 4.5"
        case .openai:    return "GPT-4o mini"
        case .ollama:    return "local model"
        }
    }

    /// Prominent tier badge label shown on the provider card.
    var badgeLabel: String {
        switch self {
        case .groq:      return "Free"
        case .gemini:    return "Cheapest"
        case .openai:    return "Balance"
        case .anthropic: return "Highest Quality"
        case .ollama:    return "Local"
        }
    }

    /// Badge background colour.
    var badgeColor: Color {
        switch self {
        case .groq:      return .green
        case .gemini:    return .green
        case .openai:    return .blue
        case .anthropic: return .purple
        case .ollama:    return .secondary
        }
    }

    /// One-line tagline beneath the provider name.
    var tagline: String {
        switch self {
        case .groq:      return "Fast · Good for simple document analyses"
        case .gemini:    return "Fastest with fairly good reasoning"
        case .anthropic: return "Deepest reasoning · Best for power users"
        case .openai:    return "Better reasoning · Balance between quality, speed & price"
        case .ollama:    return "Runs on your Mac · Limited to your hardware"
        }
    }

    /// Model identifier + cost line shown as caption.
    ///
    /// Typical Dragaway task ≈ 1,500 tokens in + 400 tokens out:
    ///   Groq / Llama 3.1 8B   → free tier available, ~10,000 interactions per $5
    ///   Claude Haiku 4.5      → ~385 interactions per $5
    ///   GPT-4o mini           → ~2,800 interactions per $5
    ///   Ollama                → free local inference
    var pricingSubtitle: String {
        switch self {
        case .groq:
            return "Llama 3.1 8B · Free tier available · ~10,000 interactions* per $5"
        case .gemini:
            return "Gemini 2.5 Flash · Cheapest · Fastest with fairly good reasoning"
        case .anthropic:
            return "Claude Haiku 4.5 · ~400 interactions* per $5"
        case .openai:
            return "GPT-4o mini · ~2,800 interactions* per $5"
        case .ollama:
            return "Any local model · Free · No internet or API key required"
        }
    }

    /// Whether this provider requires a paid/registered API key.
    var requiresAPIKey: Bool {
        self != .ollama
    }

    /// Badge tint — green for free options, blue/default for paid.
    var isFree: Bool {
        self == .groq || self == .ollama
    }
}
