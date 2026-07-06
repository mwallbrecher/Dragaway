import Foundation

// GPT-4o-mini — BYOK
// API key from: https://platform.openai.com

final class OpenAIProvider: AIProvider {
    let name = "OpenAI"
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": openAICompatMessages(messages, imageURL: imageURL, attachImage: true),
            "max_tokens": plan.maxOutputTokens,
            "temperature": 0.3
        ]
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
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": openAICompatMessages(messages, imageURL: imageURL, attachImage: true),
            "max_tokens": plan.maxOutputTokens,
            "temperature": 0.3,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await openAICompatSSE(request: request, onDelta: onDelta)
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
