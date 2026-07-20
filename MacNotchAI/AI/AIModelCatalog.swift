import Combine
import CryptoKit
import Foundation

/// One exact provider-side model identifier. The ID is sent unchanged in requests;
/// `displayName` is presentation only.
struct AIModelDescriptor: Codable, Hashable, Identifiable, Sendable {
    let provider: AIProviderType
    let modelID: String
    let displayName: String
    let supportsVision: Bool?
    let supportsThinking: Bool?
    let isKnown: Bool
    let isPreview: Bool
    let isAlias: Bool
    let isLegacy: Bool

    var id: String { modelID }

    var displayLabel: String {
        var label = displayName
        if isPreview,
           !label.localizedCaseInsensitiveContains("preview"),
           !label.localizedCaseInsensitiveContains("experimental") {
            label += " (Preview)"
        }
        if isAlias, !label.localizedCaseInsensitiveContains("alias") {
            label += " (Alias)"
        }
        if isLegacy, !label.localizedCaseInsensitiveContains("legacy") {
            label += " (Legacy)"
        }
        return label
    }
}

/// Live provider model lists plus the user's exact, per-provider selection.
///
/// Refreshing is deliberately opt-in from Provider Settings (with a 24-hour cache):
/// opening the pill and starting a request never waits for catalogue networking.
@MainActor
final class AIModelCatalogStore: ObservableObject {
    static let shared = AIModelCatalogStore()

    @Published private(set) var modelsByProvider: [AIProviderType: [AIModelDescriptor]] = [:]
    @Published private(set) var loadingProviders: Set<AIProviderType> = []
    @Published private(set) var errorsByProvider: [AIProviderType: String] = [:]
    @Published private(set) var lastRefreshedByProvider: [AIProviderType: Date] = [:]

    // v2 aligns Gemini's cached list with the OpenAI-compatible models endpoint.
    // Do not reuse the earlier native-generateContent catalogue for Chat Completions.
    private static let cacheKey = "ai.modelCatalog.v2"
    private static let selectionPrefix = "ai.selectedModel.v1."
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private var credentialFingerprints: [AIProviderType: String] = [:]

    private init() {
        loadCache()

        if UserDefaults.standard.object(forKey: "selectedProvider") == nil {
            UserDefaults.standard.set(AIProviderType.groq.rawValue, forKey: "selectedProvider")
        }

        // One-time migration from the previously hard-coded routes. Existing users
        // keep the exact model they already had; a genuinely fresh install may use a
        // current replacement for a legacy default.
        let isExistingInstall = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        for type in AIProviderType.allCases {
            let key = selectionKey(for: type)
            if UserDefaults.standard.string(forKey: key) == nil {
                let initial = isExistingInstall
                    ? type.defaultModelID
                    : type.newInstallDefaultModelID
                UserDefaults.standard.set(initial, forKey: key)
            }
        }
    }

    func selectedModelID(for type: AIProviderType) -> String {
        let key = selectionKey(for: type)
        if let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        // Defensive repair for cleared/corrupt defaults. Persisting one setup default
        // is deterministic configuration, not per-request automatic routing.
        UserDefaults.standard.set(type.newInstallDefaultModelID, forKey: key)
        return type.newInstallDefaultModelID
    }

    func setSelectedModelID(_ modelID: String, for type: AIProviderType) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedModelID(for: type) else { return }
        UserDefaults.standard.set(trimmed, forKey: selectionKey(for: type))
        objectWillChange.send()
        NotificationCenter.default.post(name: .aiProviderConfigurationChanged, object: type)
    }

    func availableModels(for type: AIProviderType) -> [AIModelDescriptor] {
        modelsByProvider[type] ?? []
    }

    func knownModels(for type: AIProviderType) -> [AIModelDescriptor] {
        availableModels(for: type).filter(\.isKnown)
    }

    func otherModels(for type: AIProviderType) -> [AIModelDescriptor] {
        availableModels(for: type).filter { !$0.isKnown }
    }

    func selectedDescriptor(for type: AIProviderType) -> AIModelDescriptor {
        let selected = selectedModelID(for: type)
        if let live = availableModels(for: type).first(where: { $0.modelID == selected }) {
            return live
        }
        return Self.makeDescriptor(provider: type, modelID: selected)
    }

    /// A missing selection is only considered unavailable after a successful full
    /// catalogue refresh. A network failure leaves availability unknown.
    func selectedModelIsUnavailable(for type: AIProviderType) -> Bool {
        guard lastRefreshedByProvider[type] != nil else { return false }
        let selected = selectedModelID(for: type)
        return !availableModels(for: type).contains { $0.modelID == selected }
    }

    /// Available entries plus the current selection when it is stale/unavailable.
    /// This keeps Picker tags valid and makes the no-silent-fallback rule visible.
    func modelOptions(for type: AIProviderType) -> [AIModelDescriptor] {
        let available = availableModels(for: type)
        let selected = selectedModelID(for: type)
        guard !available.contains(where: { $0.modelID == selected }) else { return available }
        return [selectedDescriptor(for: type)] + available
    }

    func isConfigured(_ type: AIProviderType) -> Bool {
        if type == .ollama {
            return !availableModels(for: type).isEmpty
                || AIProviderType(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") == .ollama
        }
        let key = KeychainManager.shared.load(service: type.keychainService)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    func refresh(_ type: AIProviderType, force: Bool = false) async {
        guard !loadingProviders.contains(type) else { return }

        if !force,
           let refreshed = lastRefreshedByProvider[type],
           Date().timeIntervalSince(refreshed) < Self.cacheLifetime {
            return
        }

        let apiKey: String
        if type.requiresAPIKey {
            apiKey = KeychainManager.shared.load(service: type.keychainService)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !apiKey.isEmpty else {
                setError("Save an API key before refreshing models.", for: type)
                return
            }
        } else {
            apiKey = ""
        }

        let fingerprint = credentialFingerprint(for: type, apiKey: apiKey)
        if let previous = credentialFingerprints[type], previous != fingerprint {
            // A different account may expose a different catalogue. Never present the
            // previous account's cached models as if they belonged to the new key.
            var models = modelsByProvider
            var dates = lastRefreshedByProvider
            models[type] = nil
            dates[type] = nil
            modelsByProvider = models
            lastRefreshedByProvider = dates
        }

        loadingProviders.insert(type)
        errorsByProvider[type] = nil
        defer { loadingProviders.remove(type) }

        do {
            let fetched = try await fetchModels(for: type, apiKey: apiKey)
            guard !fetched.isEmpty else {
                throw CatalogError.invalidResponse("The provider returned no compatible chat models.")
            }

            var models = modelsByProvider
            var dates = lastRefreshedByProvider
            models[type] = fetched
            dates[type] = Date()
            modelsByProvider = models
            lastRefreshedByProvider = dates
            credentialFingerprints[type] = fingerprint
            errorsByProvider[type] = nil
            saveCache()
            NotificationCenter.default.post(name: .aiProviderConfigurationChanged, object: type)
        } catch {
            setError(error.localizedDescription, for: type)
        }
    }

    // MARK: - Fetching

    private func fetchModels(
        for type: AIProviderType,
        apiKey: String
    ) async throws -> [AIModelDescriptor] {
        let descriptors: [AIModelDescriptor]
        switch type {
        case .openai:
            descriptors = try await fetchOpenAICompatibleModels(
                provider: .openai,
                endpoint: "https://api.openai.com/v1/models",
                apiKey: apiKey
            )
        case .groq:
            descriptors = try await fetchOpenAICompatibleModels(
                provider: .groq,
                endpoint: "https://api.groq.com/openai/v1/models",
                apiKey: apiKey
            )
        case .anthropic:
            descriptors = try await fetchAnthropicModels(apiKey: apiKey)
        case .gemini:
            // Match the exact API surface used by GeminiProvider. Google's native
            // /v1beta/models list can include generateContent-only models that are
            // not guaranteed to work through OpenAI-compatible Chat Completions.
            descriptors = try await fetchOpenAICompatibleModels(
                provider: .gemini,
                endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/models",
                apiKey: apiKey
            )
        case .ollama:
            descriptors = try await fetchOllamaModels()
        }
        return Self.sorted(descriptors)
    }

    private func fetchOpenAICompatibleModels(
        provider: AIProviderType,
        endpoint: String,
        apiKey: String
    ) async throws -> [AIModelDescriptor] {
        guard let url = URL(string: endpoint) else {
            throw CatalogError.invalidResponse("Invalid model-list URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await responseData(for: request)
        let response = try JSONDecoder().decode(OpenAIModelList.self, from: data)

        return response.data.compactMap { model in
            if provider == .groq, model.active == false { return nil }
            guard Self.isCompatibleChatModel(model.id, provider: provider) else { return nil }
            return Self.makeDescriptor(provider: provider, modelID: model.id)
        }
    }

    private func fetchAnthropicModels(apiKey: String) async throws -> [AIModelDescriptor] {
        var all: [AIModelDescriptor] = []
        var afterID: String?

        for _ in 0..<10 {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = items

            var request = URLRequest(url: components.url!, timeoutInterval: 12)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let data = try await responseData(for: request)
            let response = try JSONDecoder().decode(AnthropicModelList.self, from: data)

            all.append(contentsOf: response.data.map { model in
                Self.makeDescriptor(
                    provider: .anthropic,
                    modelID: model.id,
                    displayName: model.displayName,
                    supportsVision: model.capabilities?.imageInput?.supported
                )
            })

            guard response.hasMore == true, let lastID = response.lastID, !lastID.isEmpty else {
                break
            }
            afterID = lastID
        }
        return all
    }

    private func fetchOllamaModels() async throws -> [AIModelDescriptor] {
        var request = URLRequest(
            url: URL(string: "http://localhost:11434/api/tags")!,
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        let data = try await responseData(for: request)
        let response = try JSONDecoder().decode(OllamaModelList.self, from: data)

        var models: [AIModelDescriptor] = []
        for tag in response.models {
            let modelID = tag.name ?? tag.model ?? ""
            guard !modelID.isEmpty,
                  Self.isCompatibleChatModel(modelID, provider: .ollama)
            else { continue }

            let capabilities = try? await fetchOllamaCapabilities(modelID: modelID)
            if let capabilities, !capabilities.contains("completion") { continue }

            models.append(Self.makeDescriptor(
                provider: .ollama,
                modelID: modelID,
                displayName: modelID,
                supportsVision: capabilities?.contains("vision"),
                supportsThinking: capabilities?.contains("thinking")
            ))
        }
        return models
    }

    private func fetchOllamaCapabilities(modelID: String) async throws -> Set<String> {
        var request = URLRequest(
            url: URL(string: "http://localhost:11434/api/show")!,
            timeoutInterval: 3
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID])
        let data = try await responseData(for: request)
        let response = try JSONDecoder().decode(OllamaShowResponse.self, from: data)
        guard let capabilities = response.capabilities else {
            throw CatalogError.invalidResponse("This Ollama version does not report model capabilities.")
        }
        return Set(capabilities)
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.remote(
                data.apiErrorMessage() ?? "Model refresh failed (HTTP \(http.statusCode))."
            )
        }
        return data
    }

    // MARK: - Cache

    private struct CachedCatalogue: Codable {
        let entries: [CachedProvider]
    }

    private struct CachedProvider: Codable {
        let provider: AIProviderType
        let models: [AIModelDescriptor]
        let refreshedAt: Date
        let credentialFingerprint: String
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(CachedCatalogue.self, from: data)
        else { return }

        var models: [AIProviderType: [AIModelDescriptor]] = [:]
        var dates: [AIProviderType: Date] = [:]
        var fingerprints: [AIProviderType: String] = [:]

        for entry in cache.entries {
            let currentFingerprint = credentialFingerprint(
                for: entry.provider,
                apiKey: entry.provider.requiresAPIKey
                    ? (KeychainManager.shared.load(service: entry.provider.keychainService) ?? "")
                    : ""
            )
            guard currentFingerprint == entry.credentialFingerprint else { continue }
            models[entry.provider] = entry.models
            dates[entry.provider] = entry.refreshedAt
            fingerprints[entry.provider] = entry.credentialFingerprint
        }

        modelsByProvider = models
        lastRefreshedByProvider = dates
        credentialFingerprints = fingerprints
    }

    private func saveCache() {
        let entries = AIProviderType.allCases.compactMap { type -> CachedProvider? in
            guard let models = modelsByProvider[type],
                  let refreshedAt = lastRefreshedByProvider[type],
                  let fingerprint = credentialFingerprints[type]
            else { return nil }
            return CachedProvider(
                provider: type,
                models: models,
                refreshedAt: refreshedAt,
                credentialFingerprint: fingerprint
            )
        }
        guard let data = try? JSONEncoder().encode(CachedCatalogue(entries: entries)) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private func credentialFingerprint(for type: AIProviderType, apiKey: String) -> String {
        guard type.requiresAPIKey else { return "local" }
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func selectionKey(for type: AIProviderType) -> String {
        Self.selectionPrefix + type.storageKey
    }

    private func setError(_ message: String, for type: AIProviderType) {
        errorsByProvider[type] = message
    }

    // MARK: - Compatibility metadata

    private static func makeDescriptor(
        provider: AIProviderType,
        modelID: String,
        displayName suppliedName: String? = nil,
        supportsVision suppliedVision: Bool? = nil,
        supportsThinking suppliedThinking: Bool? = nil
    ) -> AIModelDescriptor {
        let knownName = knownModelNames[provider]?[modelID]
        let displayName = knownName
            ?? suppliedName?.nonEmpty
            ?? friendlyName(for: modelID)
        let preview = {
            let lower = modelID.lowercased()
            return lower.contains("preview")
                || lower.contains("experimental")
                || lower.contains("-exp")
        }()

        return AIModelDescriptor(
            provider: provider,
            modelID: modelID,
            displayName: displayName,
            supportsVision: suppliedVision ?? inferredVisionSupport(provider: provider, modelID: modelID),
            supportsThinking: suppliedThinking ?? inferredThinkingSupport(provider: provider, modelID: modelID),
            isKnown: knownName != nil
                || provider == .anthropic
                || provider == .gemini
                || provider == .ollama,
            isPreview: preview,
            isAlias: modelID.localizedCaseInsensitiveContains("latest"),
            isLegacy: legacyModelIDs[provider]?.contains(modelID) == true
        )
    }

    private static func sorted(_ models: [AIModelDescriptor]) -> [AIModelDescriptor] {
        let deduped = Dictionary(grouping: models, by: \.modelID).compactMap(\.value.first)
        return deduped.sorted { lhs, rhs in
            if lhs.isKnown != rhs.isKnown { return lhs.isKnown && !rhs.isKnown }
            if lhs.isLegacy != rhs.isLegacy { return !lhs.isLegacy && rhs.isLegacy }
            if lhs.isPreview != rhs.isPreview { return !lhs.isPreview && rhs.isPreview }
            if lhs.isAlias != rhs.isAlias { return !lhs.isAlias && rhs.isAlias }
            // Natural descending order keeps newer numbered families (3.5 before 2.5)
            // prominent without maintaining another version list that can go stale.
            return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedDescending
        }
    }

    private static func isCompatibleChatModel(
        _ modelID: String,
        provider: AIProviderType
    ) -> Bool {
        let lower = modelID.lowercased()
        let excludedFragments = [
            "embedding", "embed-", "whisper", "transcri", "tts", "audio",
            "realtime", "moderation", "dall-e", "image-generation", "gpt-image",
            "imagen", "veo-", "sora", "robotics", "aqa", "prompt-guard",
            "safeguard", "-guard", "/guard", "orpheus", "babbage", "davinci",
            "codex"
        ]
        if lower.hasPrefix("ft:") || excludedFragments.contains(where: lower.contains) {
            return false
        }
        if provider == .openai {
            // OpenAI's generic model list also contains models for specialised
            // endpoints. Dragaway currently uses Chat Completions, so do not offer
            // choices that are known to require Responses or another dedicated API.
            if lower.contains("deep-research")
                || lower.contains("computer-use")
                || lower.contains("chatgpt")
                || lower.contains("-pro") {
                return false
            }
        }
        if provider == .gemini {
            guard !lower.contains("-live"), !lower.contains("-image") else { return false }
            return lower.hasPrefix("gemini-") || lower.hasPrefix("gemma-")
        }
        return true
    }

    private static func inferredVisionSupport(
        provider: AIProviderType,
        modelID: String
    ) -> Bool? {
        let lower = modelID.lowercased()
        switch provider {
        case .openai:
            if lower == "chat-latest"
                || lower.contains("gpt-4o")
                || lower.contains("gpt-4.1")
                || lower.contains("gpt-4.5")
                || lower.contains("gpt-4-turbo")
                || lower.contains("gpt-5")
                || lower.contains("gpt-4-vision") {
                return true
            }
            if lower.hasPrefix("o1") {
                return !lower.hasPrefix("o1-mini") && !lower.hasPrefix("o1-preview")
            }
            if lower.hasPrefix("o3") {
                return !lower.hasPrefix("o3-mini")
            }
            if lower.hasPrefix("o4") {
                return true
            }
            if lower.contains("gpt-3.5") || lower.hasPrefix("gpt-4") {
                return false
            }
            return nil
        case .anthropic:
            return lower.contains("claude-3") || lower.contains("claude-4")
        case .gemini:
            if lower.hasPrefix("gemini-")
                || lower.hasPrefix("gemma-4-")
                || lower == "gemma-3-27b-it" {
                return true
            }
            if lower.hasPrefix("gemma-") { return false }
            return nil
        case .groq:
            if lower.contains("llama-4-scout")
                || lower.contains("llama-4-maverick")
                || lower.contains("qwen3.6-27b") {
                return true
            }
            return false
        case .ollama:
            if ["llava", "vision", "gemma3", "minicpm-v", "qwen-vl", "qwen2.5vl"]
                .contains(where: lower.contains) {
                return true
            }
            return nil
        }
    }

    private static func inferredThinkingSupport(
        provider: AIProviderType,
        modelID: String
    ) -> Bool? {
        let lower = modelID.lowercased()
        switch provider {
        case .gemini:
            if lower.contains("2.5") || lower.contains("gemini-3") { return true }
            return nil
        case .openai:
            if lower.hasPrefix("o1")
                || lower.hasPrefix("o3")
                || lower.hasPrefix("o4")
                || lower.hasPrefix("gpt-5") {
                return true
            }
            return false
        case .groq:
            return lower.contains("gpt-oss") || lower.contains("qwen3")
        case .ollama:
            if lower.contains("deepseek-r1") || lower.contains("qwen3") {
                return true
            }
            return nil
        case .anthropic:
            // Claude thinking is opt-in and Dragaway's Messages request does not enable
            // it, so the ordinary output cap remains the correct wire behavior.
            return false
        }
    }

    private static func friendlyName(for modelID: String) -> String {
        let replacements: [String: String] = [
            "gpt": "GPT", "oss": "OSS", "claude": "Claude", "gemini": "Gemini",
            "llama": "Llama", "qwen": "Qwen", "mixtral": "Mixtral", "vl": "VL"
        ]
        let spaced = modelID
            .replacingOccurrences(of: "/", with: " / ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return spaced.split(separator: " ").map { raw in
            let token = String(raw)
            return replacements[token.lowercased()] ?? token
        }.joined(separator: " ")
    }

    private static let knownModelNames: [AIProviderType: [String: String]] = [
        .openai: [
            "gpt-5.6": "GPT-5.6",
            "gpt-5.6-sol": "GPT-5.6 Sol",
            "gpt-5.6-terra": "GPT-5.6 Terra",
            "gpt-5.6-luna": "GPT-5.6 Luna",
            "gpt-5.5": "GPT-5.5",
            "gpt-5.4": "GPT-5.4",
            "gpt-5.4-mini": "GPT-5.4 mini",
            "gpt-5.4-nano": "GPT-5.4 nano",
            "gpt-5": "GPT-5",
            "gpt-5-mini": "GPT-5 mini",
            "gpt-5-nano": "GPT-5 nano",
            "chat-latest": "Chat Latest",
            "gpt-4.1": "GPT-4.1",
            "gpt-4.1-mini": "GPT-4.1 mini",
            "gpt-4.1-nano": "GPT-4.1 nano",
            "gpt-4o": "GPT-4o",
            "gpt-4o-mini": "GPT-4o mini",
            "o3": "o3",
            "o3-mini": "o3-mini",
            "o4-mini": "o4-mini"
        ],
        .anthropic: [
            "claude-opus-4-1-20250805": "Claude Opus 4.1",
            "claude-sonnet-4-20250514": "Claude Sonnet 4",
            "claude-haiku-4-5-20251001": "Claude Haiku 4.5"
        ],
        .gemini: [
            "gemini-2.5-pro": "Gemini 2.5 Pro",
            "gemini-2.5-flash": "Gemini 2.5 Flash",
            "gemini-2.5-flash-lite": "Gemini 2.5 Flash-Lite",
            "gemini-2.0-flash": "Gemini 2.0 Flash"
        ],
        .groq: [
            "openai/gpt-oss-120b": "GPT OSS 120B",
            "openai/gpt-oss-20b": "GPT OSS 20B",
            "qwen/qwen3.6-27b": "Qwen 3.6 27B",
            "qwen/qwen3-32b": "Qwen 3 32B",
            "meta-llama/llama-4-maverick-17b-128e-instruct": "Llama 4 Maverick",
            "meta-llama/llama-4-scout-17b-16e-instruct": "Llama 4 Scout",
            "llama-3.3-70b-versatile": "Llama 3.3 70B",
            "llama-3.1-8b-instant": "Llama 3.1 8B Instant"
        ],
        .ollama: [:]
    ]

    /// Small hand-maintained lifecycle layer for warnings providers do not expose in
    /// their generic model-list response. It never changes the user's selection.
    private static let legacyModelIDs: [AIProviderType: Set<String>] = [
        .groq: ["llama-3.1-8b-instant"]
    ]
}

private enum CatalogError: LocalizedError {
    case remote(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .remote(let message), .invalidResponse(let message):
            return message
        }
    }
}

private struct OpenAIModelList: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
        let active: Bool?
    }
}

private struct AnthropicModelList: Decodable {
    let data: [Model]
    let hasMore: Bool?
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }

    struct Model: Decodable {
        let id: String
        let displayName: String?
        let capabilities: Capabilities?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case capabilities
        }
    }

    struct Capabilities: Decodable {
        let imageInput: Support?

        enum CodingKeys: String, CodingKey {
            case imageInput = "image_input"
        }
    }

    struct Support: Decodable {
        let supported: Bool?
    }
}

private struct OllamaModelList: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String?
        let model: String?
    }
}

private struct OllamaShowResponse: Decodable {
    let capabilities: [String]?
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
