import Foundation

// Gemini 2.5 Flash — BYOK
// API key from: https://aistudio.google.com/apikey
// Uses Google's OpenAI-compatible endpoint, so it reuses OpenAICompatibleResponse.

final class GeminiProvider: AIProvider {
    let name = "Gemini"
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    /// Tier-aware model pick — BYOK applies the SAME cost discipline as the hosted
    /// Worker (see ModelRouting): mechanical/bounded work (`.fast`) runs on the cheap
    /// flash-lite; anything needing judgement (`.strong`) runs on flash. `.extraStrong`
    /// is a hosted-Pro-only tier — BYOK never escalates to the top model (mirrors the
    /// Worker's "free degrades extra→strong" rule and the no-escalation note in
    /// OverlayView), so it also resolves to flash.
    private func model(for tier: AITier) -> String {
        switch tier {
        case .fast:                   return "gemini-2.5-flash-lite"
        case .strong, .extraStrong:   return "gemini-2.5-flash"
        }
    }

    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }
        let model = model(for: plan.tier)

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Gemini 2.5 Flash spends "thinking" tokens that count against max_tokens on
        // Google's OpenAI-compat endpoint. A tight per-action ceiling could be eaten
        // entirely by thinking, starving the visible answer (the 2.5-Flash cutoff —
        // see lessons). So add reasoning headroom + a floor on top of the requested
        // ceiling, with reasoning_effort: low to keep thinking minimal.
        let cap = max(plan.maxOutputTokens + 1024, 2048)
        let body: [String: Any] = [
            "model": model,
            "messages": openAICompatMessages(messages, imageURL: imageURL, attachImage: true),
            "max_tokens": cap,
            "temperature": 0.3,
            "reasoning_effort": "low"
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
        // Same thinking-token headroom as reply() — see the cutoff note above.
        let cap = max(plan.maxOutputTokens + 1024, 2048)
        let body: [String: Any] = [
            "model": model(for: plan.tier),
            "messages": openAICompatMessages(messages, imageURL: imageURL, attachImage: true),
            "max_tokens": cap,
            "temperature": 0.3,
            "reasoning_effort": "low",
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await openAICompatSSE(request: request, onDelta: onDelta)
    }
}
