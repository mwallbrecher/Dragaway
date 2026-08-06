import SwiftUI
import AppKit

/// The "Expose Session" panel. `docs/SHARE_ARCHITECTURE.md` §5.
///
/// The disclosure text is the point of this screen, not decoration: it names the file that
/// will leave the Mac, how it is encrypted, WHO CAN READ IT, and when it disappears — and it
/// changes live when a password is set, because that genuinely changes the answer.
struct ExposeSessionView: View {

    let fileURL: URL
    let turns: [SessionTurn]
    var onClose: () -> Void

    @ObservedObject private var controller = ShareController.shared
    @State private var password = ""
    @State private var usePassword = false
    @State private var copied = false

    private var hasPassword: Bool { usePassword && !password.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.vertical, 14)

            switch controller.phase {
            case .idle:                        idleState
            case .packing, .uploading:         busyState
            case .exposed(let code, let exp, let pw): exposedState(code: code, expires: exp, hadPassword: pw)
            case .failed(let message):         failedState(message)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { controller.prepare(fileURL: fileURL, turns: turns) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Expose Session").font(.system(size: 16, weight: .semibold))
                Text("Share it with a colleague").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Before exposing

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 16) {
            disclosure

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $usePassword) {
                    Text("Protect with a password").font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)

                if usePassword {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                    Text("Send the password through a different channel than the code.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Button {
                controller.expose(fileURL: fileURL, turns: turns,
                                  password: hasPassword ? password : nil)
            } label: {
                Text("Expose Session").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(usePassword && password.isEmpty)
        }
    }

    /// The honest disclosure. Two variants, because the security guarantee genuinely differs
    /// (§2) — claiming end-to-end encryption without a password would be false.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 9) {
            row("doc.fill", "What leaves your Mac",
                "\(controller.pendingFileName)\(controller.pendingSize.isEmpty ? "" : " · \(controller.pendingSize)") and this session's AI results. Nothing else.")

            if hasPassword {
                row("lock.fill", "End-to-end encrypted",
                    "The key is derived from your password and never leaves this Mac. Without it nobody can read the data — not even we can.")
            } else {
                row("lock", "Encrypted, but we hold the key",
                    "Encrypted before upload (AES-256). Stored on Dragaway's server and protected by an attempt limit — technically we could read it. Set a password for confidential material.")
            }

            row("clock.arrow.circlepath", "Deleted",
                "As soon as your colleague has it, at the latest after 24 hours. You can revoke it any time.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func row(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(hasPassword && icon == "lock.fill" ? .green : .secondary)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(body).font(.system(size: 11.5)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Busy

    private var busyState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(controller.phase == .packing ? "Encrypting…" : "Uploading…")
                .font(.system(size: 12.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    // MARK: Exposed — the code

    private func exposedState(code: String, expires: Date, hadPassword: Bool) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Share this code").font(.system(size: 12)).foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Text(formatted(code))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your colleague opens Dragaway → Join Session → enters this code.")
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
                if hadPassword {
                    Label("They will also need the password.", systemImage: "lock.fill")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Label("Valid until \(expires.formatted(date: .omitted, time: .shortened))",
                      systemImage: "clock")
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
            }

            HStack {
                Button("Revoke now") { controller.revoke() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { controller.reset(); onClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// 123456 → "123 456" — easier to read aloud, still one value on the clipboard.
    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let i = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<i]) \(code[i...])"
    }

    // MARK: Failure

    private func failedState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Try again") { controller.reset() }.buttonStyle(.bordered)
                Button("Close") { controller.reset(); onClose() }.buttonStyle(.borderedProminent)
            }
        }
    }
}
