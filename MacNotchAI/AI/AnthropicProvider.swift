import Foundation

// Anthropic — BYOK, exact model injected from AIModelCatalogStore.
// API key from: https://console.anthropic.com

final class AnthropicProvider: AIProvider {
    let name = "Anthropic"
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let modelID: String
    private let supportsVision: Bool
    /// Anthropic won't cache a block below ~2048 tokens on Haiku. At ~4 chars/token
    /// that's ~8k chars; below it we skip the `cache_control` mark entirely.
    private static let cacheMinChars = 8000

    init(apiKey: String, modelID: String, supportsVision: Bool) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.supportsVision = supportsVision
    }
    var isAvailable: Bool { !apiKey.isEmpty }

    func reply(messages turns: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }
        try requireImageSupport(
            imageURL: imageURL,
            supportsVision: supportsVision,
            provider: name,
            modelID: modelID
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(turns: turns, imageURL: imageURL, plan: plan))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return decoded.content.compactMap(\.text).first ?? "No response"
    }

    func replyStream(messages turns: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
                     onDelta: @escaping (String) -> Void) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }
        try requireImageSupport(
            imageURL: imageURL,
            supportsVision: supportsVision,
            provider: name,
            modelID: modelID
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body = requestBody(turns: turns, imageURL: imageURL, plan: plan)
        body["stream"] = true
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // See openAICompatSSE: forbid gzip so URLSession doesn't buffer the event
        // stream until completion (which makes streaming look like a one-shot reply).
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
        }

        // Anthropic SSE: `data: {"type":"content_block_delta","delta":{"text":…}}`.
        struct Event: Decodable {
            struct Delta: Decodable { let text: String? }
            let type: String
            let delta: Delta?
        }
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: d) else { continue }
            if event.type == "message_stop" { break }
            if event.type == "content_block_delta",
               let text = event.delta?.text, !text.isEmpty {
                full += text
                onDelta(text)
            }
        }
        guard !full.isEmpty else { throw AIError.apiError("Empty response") }
        return full
    }

    /// Anthropic wire body shared by reply/replyStream: system prompt in its own
    /// top-level field, image + cacheable document folded into the first user turn.
    private func requestBody(turns: [ChatTurn], imageURL: URL?, plan: RoutingPlan) -> [String: Any] {
        // Anthropic takes the system prompt in a separate top-level field; only
        // user/assistant turns go in `messages`. Image is inlined into the FIRST
        // user turn using Anthropic's own content-block format.
        let systemPrompt = turns.filter { $0.role == "system" }
            .map(\.content).joined(separator: "\n\n")

        var imageUsed = false
        let messages: [[String: Any]] = turns.compactMap { turn in
            guard turn.role == "user" || turn.role == "assistant" else { return nil }
            if supportsVision, turn.role == "user", !imageUsed,
               let imageURL, FileInspector.isImageFile(imageURL),
               let imageData = try? Data(contentsOf: imageURL) {
                imageUsed = true
                let base64 = imageData.base64EncodedString()
                let mime = mimeType(for: imageURL)
                return [
                    "role": "user",
                    "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]],
                        ["type": "text", "text": turn.flattenedContent]
                    ]
                ]
            }
            // Document on the first user turn → split into a cacheable block. The doc
            // is byte-identical on every follow-up, so the prefix [system + this turn]
            // hits the cache (~90% off the replayed document tokens). Only mark it when
            // it's plausibly above Haiku's ~2048-token cache minimum — below that the
            // mark is a no-op and a short prompt isn't worth caching anyway.
            if turn.role == "user", let doc = turn.cacheableDocument,
               doc.count >= Self.cacheMinChars {
                return [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": turn.content],
                        ["type": "text", "text": "--- Document(s) ---\n" + doc,
                         "cache_control": ["type": "ephemeral"]]
                    ]
                ]
            }
            return ["role": turn.role, "content": turn.flattenedContent]
        }

        return [
            "model": modelID,
            "system": systemPrompt,
            "messages": messages,
            "max_tokens": plan.maxOutputTokens
        ]
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        default:            return "image/jpeg"
        }
    }
}

struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    struct ContentBlock: Decodable {
        let text: String?
    }
}
