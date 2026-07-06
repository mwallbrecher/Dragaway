import AppKit

/// Submits in-app feedback. Primary path: POST to the Cloudflare Worker
/// (`/v1/feedback`). If that's unreachable or the backend URL is unset, it falls back
/// to a prefilled `mailto:` so a report is never silently lost.
enum FeedbackSender {

    enum Topic: String, CaseIterable, Identifiable {
        case bug      = "Bug"
        case idea     = "Idea"
        case feedback = "Feedback"
        case question = "Question"
        case other    = "Other"
        var id: String { rawValue }
    }

    /// Where the mailto fallback is addressed.
    static let fallbackEmail = "moritz.wallbrecher2@gmail.com"

    enum Outcome { case sent, mailFallback, failed }

    /// Send the report. Runs the network POST off the main actor; the mailto fallback
    /// (if needed) is opened on the main actor.
    static func send(name: String, topic: Topic, message: String) async -> Outcome {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString

        if let base = BackendConfig.proxyBaseURL {
            var req = URLRequest(url: base.appendingPathComponent("v1/feedback"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
            req.timeoutInterval = 15
            let payload: [String: Any] = [
                "name": name,
                "topic": topic.rawValue,
                "message": message,
                "appVersion": appVersion,
                "os": os,
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return .sent
            }
        }

        // Fallback — open the user's mail client with everything prefilled.
        let opened = await MainActor.run {
            openMail(name: name, topic: topic, message: message, appVersion: appVersion)
        }
        return opened ? .mailFallback : .failed
    }

    @MainActor
    private static func openMail(name: String, topic: Topic, message: String,
                                 appVersion: String) -> Bool {
        let subject = "[\(topic.rawValue)] Dragaway feedback"
        let body = """
        From: \(name.isEmpty ? "(anonymous)" : name)
        App version: \(appVersion)

        \(message)
        """
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = fallbackEmail
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = comps.url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
