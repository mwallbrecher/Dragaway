import Foundation

// Gemini — BYOK, exact model injected from AIModelCatalogStore.
// API key from: https://aistudio.google.com/apikey
// Uses Google's OpenAI-compatible endpoint, so it reuses OpenAICompatibleResponse.

final class GeminiProvider: AIProvider {
    let name = "Gemini"
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    private let modelID: String
    private let supportsVision: Bool
    private let supportsThinking: Bool

    init(
        apiKey: String,
        modelID: String,
        supportsVision: Bool,
        supportsThinking: Bool
    ) {
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
        // Thinking-capable Gemini models spend reasoning tokens inside max_tokens.
        // Preserve the existing visible-answer headroom only when the live catalogue
        // says the selected model thinks; other model families receive the plain guard.
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
            "max_tokens": cap,
            "stream": stream
        ]
        if supportsThinking {
            body["reasoning_effort"] = "low"
        }
        if modelID.lowercased().contains("gemini-2") {
            // Keep the previous response profile for Gemini 2.x and compatible
            // snapshots. Newer/other families keep their provider defaults.
            body["temperature"] = 0.3
        }
        return body
    }
}
