import SwiftUI

/// Feedback form: name (optional) + topic + message. Submits via FeedbackSender
/// (Worker POST, mailto fallback). Opened from the menu bar; closes itself after a
/// successful send.
struct FeedbackView: View {
    var onClose: () -> Void

    @State private var name = ""
    @State private var topic: FeedbackSender.Topic = .bug
    @State private var message = ""
    @State private var sending = false
    @State private var banner: (text: String, ok: Bool)?

    private var canSend: Bool {
        !sending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            VStack(alignment: .center, spacing: 8) {
                Image(systemName: "paperplane")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.accentColor)
                Text("Send Feedback")
                    .font(.title2.bold())
                Text("Bugs, ideas, questions — it all reaches me.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.horizontal, 24)

            Divider().padding(.vertical, 16)

            // ── Form ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                TextField("Your name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("Topic", selection: $topic) {
                    ForEach(FeedbackSender.Topic.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text(placeholder)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $message)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(2)
                        .frame(height: 130)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

                if let banner {
                    Label(banner.text, systemImage: banner.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(banner.ok ? .green : .orange)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 18)

            // ── Buttons ─────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Cancel") { onClose() }
                    .controlSize(.large)

                Button(sending ? "Sending…" : "Send") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!canSend)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(width: 420)
    }

    private var placeholder: String {
        switch topic {
        case .bug:      return "What went wrong, and what were you doing when it happened?"
        case .idea:     return "What would you like Dragaway to do?"
        case .question: return "Ask away…"
        default:        return "Tell me anything."
        }
    }

    private func submit() {
        sending = true
        banner = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let outcome = await FeedbackSender.send(name: n, topic: topic, message: m)
            sending = false
            switch outcome {
            case .sent:
                banner = ("Thanks — your feedback was sent!", true)
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                onClose()
            case .mailFallback:
                banner = ("Opened your mail app — just hit send.", true)
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                onClose()
            case .failed:
                banner = ("Couldn't send right now. Try again later.", false)
            }
        }
    }
}
