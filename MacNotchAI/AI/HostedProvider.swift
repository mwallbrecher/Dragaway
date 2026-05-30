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
            return "AI Drop Free isn't available yet. Switch to your own API key in Settings."
        case .limitReached:
            return "You've used today's free interactions. Try again tomorrow or use your own API key."
        case .serviceBusy:
            return "AI Drop Free is busy right now. Try again later or use your own API key."
        }
    }
}

/// AIProvider that routes completions through the hosted metering Worker instead of
/// calling a model API directly. The host Gemini key lives only on the Worker; the app
/// authenticates the device with an anonymous `X-Device-Id`. Every response carries a
/// fresh usage snapshot which we mirror into `UsageStore`.
final class HostedProvider: AIProvider {
    let name = "AI Drop Free"

    /// Only usable once the Worker URL has been configured.
    var isAvailable: Bool { BackendConfig.proxyBaseURL != nil }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        guard let base = BackendConfig.proxyBaseURL else { throw HostedError.backendNotConfigured }

        var request = URLRequest(url: base.appendingPathComponent("v1/complete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")

        var body: [String: Any] = [
            "action": action.rawValue,
            "system": action.systemPrompt,
            "content": content,
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
