import SwiftUI
import AppKit

/// "Search Sessions" window: live-filtered list of stored sessions (filename, prompts,
/// and result text are all searched). Clicking a row reopens the session via the same
/// restore path as the Recent Sessions menu. Opened from the menu bar.
struct SessionSearchView: View {
    /// Called with the picked session id; the owner reopens it and closes the window.
    var onPick: (UUID) -> Void

    @ObservedObject private var store = SessionHistoryStore.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [SessionRecord] { store.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search field ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search file names, prompts, answers…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))

            Divider()

            // ── Results ─────────────────────────────────────────────────────
            if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary)
                    Text(store.sessions.isEmpty ? "No sessions yet"
                                                : "No sessions match “\(query)”")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { rec in
                            SessionSearchRow(record: rec, query: query) {
                                onPick(rec.id)
                            }
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .frame(width: 440, height: 380)
        .onAppear { searchFocused = true }
    }
}

private struct SessionSearchRow: View {
    let record: SessionRecord
    let query: String
    let action: () -> Void

    @State private var hovering = false

    /// The matched turn's prompt (or the last one) as the row's context line.
    private var snippet: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           let hit = record.turns.last(where: {
               $0.promptTitle.localizedCaseInsensitiveContains(q) ||
               $0.resultText.localizedCaseInsensitiveContains(q)
           }) {
            return hit.promptTitle
        }
        return record.lastTurn?.promptTitle ?? ""
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy, HH:mm"
        return f
    }()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: record.primaryPath))
                    .resizable()
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.fileName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(Self.df.string(from: record.updatedAt))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
