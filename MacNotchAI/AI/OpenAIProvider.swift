import Foundation

// OpenAI — BYOK, exact model injected from AIModelCatalogStore.
// API key from: https://platform.openai.com

final class OpenAIProvider: AIProvider {
    let name = "OpenAI"
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let modelID: String
    private let supportsVision: Bool
    private let supportsThinking: Bool

    init(apiKey: String, modelID: String, supportsVision: Bool, supportsThinking: Bool) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.supportsVision = supportsVision
        self.supportsThinking = supportsThinking
    }
    var isAvailable: Bool { !apiKey.isEmpty }

    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }
        try requireImageSupport(
            imageURL: imageURL,
            supportsVision: supportsVision,
            provider: name,
            modelID: modelID
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = requestBody(
            messages: messages,
            imageURL: imageURL,
            plan: plan,
            stream: false
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return decoded.choices.first?.message.content ?? "No response"
    }

    func replyStream(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = requestBody(
            messages: messages,
            imageURL: imageURL,
            plan: plan,
            stream: true
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await openAICompatSSE(request: request, onDelta: onDelta)
    }

    private func requestBody(
        messages: [ChatTurn],
        imageURL: URL?,
        plan: RoutingPlan,
        stream: Bool
    ) -> [String: Any] {
        let cap = supportsThinking
            ? max(plan.maxOutputTokens + 1024, 2048)
            : plan.maxOutputTokens
        var body: [String: Any] = [
            "model": modelID,
            "messages": openAICompatMessages(
                messages,
                imageURL: imageURL,
                attachImage: supportsVision
            ),
            "max_completion_tokens": cap,
            "stream": stream
        ]

        // Current GPT-5/o-series chat models account for hidden reasoning inside the
        // completion ceiling. Low effort plus headroom preserves the requested visible
        // answer length. Some Pro-only IDs fix their own effort and reject this field.
        let lower = modelID.lowercased()
        let usesLegacySamplingProfile = lower.contains("gpt-4o")
            || lower.contains("gpt-4.1")
            || lower.contains("gpt-4.5")
            || lower.contains("gpt-4-turbo")
            || lower.contains("gpt-3.5")
            || lower == "gpt-4"
            || lower.hasPrefix("gpt-4-")
        if supportsThinking, !lower.contains("-pro") {
            body["reasoning_effort"] = "low"
        } else if !supportsThinking, usesLegacySamplingProfile {
            // Preserve Dragaway's established deterministic profile for ordinary
            // legacy chat models. Unknown/future families keep provider defaults.
            body["temperature"] = 0.3
        }
        return body
    }
}

// Shared response model (Groq uses the same OpenAI-compatible format)
struct OpenAICompatibleResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String
        }
    }
}
