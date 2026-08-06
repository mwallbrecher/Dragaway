import SwiftUI
import AppKit

/// The recipient's side: enter a 6-digit code, get the session locally.
///
/// After import this is an ordinary Dragaway session — the recipient works with THEIR OWN
/// provider and API key. Nothing is sent back to the sender (fork, not sync).
struct JoinSessionView: View {

    var onImported: (URL) -> Void
    var onClose: () -> Void

    @State private var code = ""
    @State private var password = ""
    @State private var needsPassword = false
    @State private var busy = false
    @State private var error: String?

    private var normalizedCode: String {
        code.filter(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Join Session").font(.system(size: 16, weight: .semibold))
                    Text("Enter the code your colleague shared")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 14)

            TextField("000000", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .onChange(of: code) { _, new in
                    // Keep it forgiving: accept pasted spaces/dashes, cap at six digits.
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits }
                    error = nil
                }
                .disabled(busy)

            if needsPassword {
                VStack(alignment: .leading, spacing: 5) {
                    Text("This session is password-protected.")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                }
                .padding(.top, 12)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Button(action: join) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Fetching…" : "Open Session").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || normalizedCode.count != 6 || (needsPassword && password.isEmpty))
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 380)
    }

    private func join() {
        busy = true
        error = nil
        Task {
            let result = await ShareController.shared.importShare(
                code: normalizedCode, password: needsPassword ? password : nil)
            busy = false
            switch result {
            case .success(let url):
                onImported(url)
                onClose()
            case .needsPassword:
                // Also the "wrong password" path — same remedy, so the same prompt.
                if needsPassword { error = "Wrong password." }
                needsPassword = true
            case .failure(let message):
                error = message
            }
        }
    }
}
