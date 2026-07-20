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

/// Returned by provider resolution when a successful live catalogue refresh proved
/// that the exact persisted selection disappeared. It intentionally never substitutes
/// a replacement model.
struct UnavailableModelProvider: AIProvider {
    let providerName: String
    let modelID: String

    var name: String { providerName }
    var isAvailable: Bool { false }

    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        throw AIError.modelUnavailable(provider: providerName, model: modelID)
    }
}

/// A persisted route is corrupt or from an unknown provider version. Preserve the
/// failure instead of silently sending the user's document to a different provider.
struct InvalidConfigurationProvider: AIProvider {
    let message: String

    var name: String { "AI Provider" }
    var isAvailable: Bool { false }

    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        throw AIError.invalidConfiguration(message)
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

/// Do not silently discard an image when the explicitly selected model is known to be
/// text-only. Unknown capabilities are resolved conservatively by the catalogue.
func requireImageSupport(
    imageURL: URL?,
    supportsVision: Bool,
    provider: String,
    modelID: String
) throws {
    guard let imageURL, FileInspector.isImageFile(imageURL), !supportsVision else { return }
    throw AIError.imageInputUnsupported(provider: provider, model: modelID)
}

/// Build an OpenAI-compatible `messages` array from chat turns. When `attachImage`
/// is true and `imageURL` is a readable image, it is inlined (base64 data URL) into
/// the FIRST user turn. Callers validate text-only selections with
/// `requireImageSupport` before passing `attachImage: false`.
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

enum AIProviderType: String, CaseIterable, Codable, Sendable {
    case groq       = "Groq (Free)"
    case gemini     = "Gemini (Google)"
    case openai     = "OpenAI (GPT-4o)"
    case anthropic  = "Anthropic (Claude)"
    case ollama     = "Ollama (Local, Free)"
}

// MARK: - Display metadata (used by provider picker in Onboarding + Settings)

extension AIProviderType {

    /// Stable persistence key. Keep this separate from `rawValue`: raw values predate
    /// model selection and contain marketing/model copy, but are already stored by
    /// existing installations as `selectedProvider`.
    var storageKey: String {
        switch self {
        case .groq:      return "groq"
        case .gemini:    return "gemini"
        case .openai:    return "openai"
        case .anthropic: return "anthropic"
        case .ollama:    return "ollama"
        }
    }

    /// Exact one-time migration target for users coming from the hard-coded provider
    /// implementations. Once persisted, Dragaway never silently changes this value.
    var defaultModelID: String {
        switch self {
        case .groq:      return "llama-3.1-8b-instant"
        case .gemini:    return "gemini-2.5-flash"
        case .openai:    return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .ollama:    return "llama3.1"
        }
    }

    /// Starting choice for a genuinely new installation. Existing users migrate the
    /// exact legacy route above; fresh installs may start on a current replacement.
    var newInstallDefaultModelID: String {
        switch self {
        case .groq: return "openai/gpt-oss-20b"
        default:    return defaultModelID
        }
    }

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

    /// Existing Keychain service used by provider resolution and Settings.
    var keychainService: String {
        switch self {
        case .groq:      return "com.aidrop.groq"
        case .gemini:    return "com.aidrop.gemini"
        case .anthropic: return "com.aidrop.anthropic"
        case .openai:    return "com.aidrop.openai"
        case .ollama:    return "com.aidrop.ollama"
        }
    }

    /// Prominent tier badge label shown on the provider card.
    var badgeLabel: String {
        switch self {
        case .groq:      return "Free tier"
        case .gemini:    return "Google"
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
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
        case .groq:      return "Fast hosted inference · Free tier available"
        case .gemini:    return "Google models · Broad speed and quality range"
        case .anthropic: return "Claude models · Strong writing and reasoning"
        case .openai:    return "OpenAI models · Broad speed and quality range"
        case .ollama:    return "Runs on your Mac · Limited to your hardware"
        }
    }

    /// Provider-level caption. Exact price/model claims live in the model picker now,
    /// because the user may select any compatible model exposed by their account.
    var pricingSubtitle: String {
        switch self {
        case .groq:
            return "Free tier available · Choose from your live Groq models"
        case .gemini:
            return "Choose from the models available to your Google AI key"
        case .anthropic:
            return "Choose Haiku, Sonnet, Opus, or another available Claude model"
        case .openai:
            return "Choose from the models available to your OpenAI account"
        case .ollama:
            return "Any installed chat model · Free · Local"
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

/// Provider/model metadata for the live session header. Its hosted-vs-BYOK branch
/// intentionally mirrors `resolveProvider()` so the label describes the path the
/// next request will actually use, without constructing a provider or loading keys.
struct AISelectionDisplay {
    let provider: String
    let model: String
}

@MainActor
func currentAISelectionDisplay(
    selectedProviderRaw: String,
    entitlement: EntitlementStore.Tier
) -> AISelectionDisplay {
    if entitlement != .byok, BackendConfig.proxyBaseURL != nil {
        let provider = entitlement == .pro ? "Dragaway Pro" : "Dragaway Free"
        return AISelectionDisplay(provider: provider, model: "Gemini 2.5")
    }

    guard let type = AIProviderType(rawValue: selectedProviderRaw) else {
        return AISelectionDisplay(provider: "AI Provider", model: "Select model")
    }
    let descriptor = AIModelCatalogStore.shared.selectedDescriptor(for: type)
    let model = AIModelCatalogStore.shared.selectedModelIsUnavailable(for: type)
        ? "\(descriptor.displayLabel) — Unavailable"
        : descriptor.displayLabel
    return AISelectionDisplay(provider: type.displayName, model: model)
}

/// One selectable route in the header's model menu. The trigger shows only `model`;
/// `provider` is retained for disambiguation inside the menu.
struct AIModelChoice: Identifiable, Equatable {
    static let hostedID = "hosted"
    static let invalidID = "invalid-configuration"

    let id: String
    let model: String
    let provider: String
    let providerType: AIProviderType?
    let modelID: String?
    let isUnavailable: Bool

    var menuTitle: String {
        "\(model) — \(provider)" + (isUnavailable ? " (Unavailable)" : "")
    }

    static func byokID(for type: AIProviderType, modelID: String) -> String {
        // Treated as an opaque Picker tag; callers resolve it through the concrete
        // `AIModelChoice`, so Ollama colons and Groq slashes never need parsing.
        "byok:\(type.storageKey):\(modelID)"
    }

    static func selectedID(
        selectedProviderRaw: String,
        entitlement: EntitlementStore.Tier
    ) -> String {
        if entitlement != .byok, BackendConfig.proxyBaseURL != nil { return hostedID }
        guard let type = AIProviderType(rawValue: selectedProviderRaw) else {
            return invalidID
        }
        let modelID = AIModelCatalogStore.shared.selectedModelID(for: type)
        return byokID(for: type, modelID: modelID)
    }
}

/// Models the user has actually enabled: Hosted Free when available, BYOK providers
/// with a stored non-empty key, plus Ollama only while it is the active local route.
/// Deliberately performs no synchronous Ollama network probe from the menu.
@MainActor
func enabledAIModelChoices(
    selectedProviderRaw: String,
    entitlement: EntitlementStore.Tier
) -> [AIModelChoice] {
    var choices: [AIModelChoice] = []
    if BackendConfig.isBackendLive {
        choices.append(AIModelChoice(
            id: AIModelChoice.hostedID,
            model: "Gemini 2.5",
            provider: "Dragaway Free",
            providerType: nil,
            modelID: nil,
            isUnavailable: false
        ))
    }

    let selectedType = AIProviderType(rawValue: selectedProviderRaw)
    let catalog = AIModelCatalogStore.shared
    for type in AIProviderType.allCases {
        if type == .ollama {
            guard catalog.isConfigured(type)
                    || (entitlement == .byok && selectedType == .ollama)
            else { continue }
        } else {
            let key = KeychainManager.shared.load(service: type.keychainService)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }
        }

        let selectedModel = catalog.selectedModelID(for: type)
        for descriptor in catalog.modelOptions(for: type) {
            let unavailable = descriptor.modelID == selectedModel
                && catalog.selectedModelIsUnavailable(for: type)
            choices.append(AIModelChoice(
                id: AIModelChoice.byokID(for: type, modelID: descriptor.modelID),
                model: descriptor.displayLabel,
                provider: type.displayName,
                providerType: type,
                modelID: descriptor.modelID,
                isUnavailable: unavailable
            ))
        }
    }
    return choices
}
