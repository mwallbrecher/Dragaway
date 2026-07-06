import Foundation

/// Errors specific to the hosted free-tier path (talking to our Cloudflare Worker).
enum HostedError: LocalizedError {
    /// `BackendConfig.proxyBaseURL` is nil — the Worker URL hasn't been pasted in yet.
    case backendNotConfigured
    /// The device used up its daily free allowance. `resetAt` is the ISO-8601 UTC reset time.
    case limitReached(resetAt: String?)
    /// The shared free tier hit its global daily ceiling (budget circuit-breaker).
    case serviceBusy

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "Dragaway Free isn't available yet. Switch to your own API key in Settings."
        case .limitReached:
            return "You've used today's free interactions. Try again tomorrow or use your own API key."
        case .serviceBusy:
            return "Dragaway Free is busy right now. Try again later or use your own API key."
        }
    }
}

/// AIProvider that routes completions through the hosted metering Worker instead of
/// calling a model API directly. The host Gemini key lives only on the Worker; the app
/// authenticates the device with an anonymous `X-Device-Id`. Every response carries a
/// fresh usage snapshot which we mirror into `UsageStore`.
final class HostedProvider: AIProvider {
    let name = "Dragaway Free"

    /// Only usable once the Worker URL has been configured.
    var isAvailable: Bool { BackendConfig.proxyBaseURL != nil }

    func reply(messages turns: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        guard let base = BackendConfig.proxyBaseURL else { throw HostedError.backendNotConfigured }

        var request = URLRequest(url: base.appendingPathComponent("v1/complete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")

        // Send the whole conversation: system prompt separate, user/assistant
        // turns as a messages array. The Worker forwards to the host model.
        // Fold the document back into the first user turn (flattenedContent) so the
        // Worker still receives a stable leading prefix it can cache server-side.
        let system = turns.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let messages = turns.filter { $0.role != "system" }
            .map { ["role": $0.role, "content": $0.flattenedContent] }

        // Forward the routing decision so the Worker can pick the model (`tier`) and cap
        // the output (`max_tokens`). The Worker owns the key — this is where the operator's
        // bill is actually won. `tier` is a hint: the Worker falls back to the capable
        // model if it's missing or unrecognised.
        var body: [String: Any] = [
            "system": system,
            "messages": messages,
            "max_tokens": plan.maxOutputTokens,
            "tier": plan.tier.rawValue,
        ]
        if let imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            body["image"] = [
                "mime": Self.mimeType(for: imageURL),
                "data": imageData.base64EncodedString(),
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let decoded = try? JSONDecoder().decode(CompleteResponse.self, from: data)

        if let usage = decoded?.usage {
            UsageStore.shared.apply(usage)
        }

        switch http?.statusCode ?? 0 {
        case 200:
            guard let text = decoded?.text, !text.isEmpty else {
                throw AIError.apiError(decoded?.error ?? "Empty response")
            }
            return text
        case 429:
            throw HostedError.limitReached(resetAt: decoded?.usage?.resetAt)
        case 503:
            throw HostedError.serviceBusy
        default:
            throw AIError.apiError(decoded?.error ?? "HTTP \(http?.statusCode ?? 0)")
        }
    }

    private struct CompleteResponse: Decodable {
        let text: String?
        let usage: HostedUsage?
        let error: String?
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        default:            return "image/png"
        }
    }
}
