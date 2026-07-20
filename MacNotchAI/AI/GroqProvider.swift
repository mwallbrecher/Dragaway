import Foundation

// Groq offers a free tier — ideal default for new users, no credit card needed.
// Sign up at: https://console.groq.com

final class GroqProvider: AIProvider {
    let name = "Groq"
    private let apiKey: String
    private let baseURL = "https://api.groq.com/openai/v1/chat/completions"
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
        let lower = modelID.lowercased()
        let usesGPTOSSReasoning = lower.contains("gpt-oss")
        let supportsQwenThinkingToggle = lower.contains("qwen3.6-27b")
            || lower.contains("qwen3-32b")
        let cap = usesGPTOSSReasoning
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

        if usesGPTOSSReasoning {
            body["reasoning_effort"] = "low"
            body["reasoning_format"] = "hidden"
        } else if supportsThinking, supportsQwenThinkingToggle {
            // Groq documents `none`/`default` only for these Qwen variants.
            // Other qwen3-named models must keep their provider defaults.
            body["reasoning_effort"] = "none"
        }
        if !usesGPTOSSReasoning {
            body["temperature"] = 0.3
        }
        return body
    }
}
