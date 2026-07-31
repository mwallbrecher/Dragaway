import SwiftUI
import AppKit

/// Local detail and context-selection view for a dropped folder.
///
/// This deliberately stays a popover instead of introducing another overlay stage:
/// opening it cannot affect the fixed chips-window sizing or the drop state machine.
struct FolderContentsPopover: View {
    let rootURL: URL

    @ObservedObject private var store = FolderAnalysisStore.shared
    @Environment(\.uiScale) private var scale
    @State private var filter: FolderEntryFilter = .all
    @State private var selectionAnchorID: String?
    @State private var focusedEntryID: String?
    @FocusState private var hasKeyboardFocus: Bool

    private var snapshot: FolderAnalysisSnapshot {
        store.snapshot(for: rootURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar

            Divider()
                .overlay(Color.white.opacity(0.10))

            content
        }
        .frame(width: 380 * scale, height: 420 * scale, alignment: .top)
        .liquidGlass(cornerRadius: 16 * scale, tintOpacity: 0.76)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(.space) {
            previewSelection() ? .handled : .ignored
        }
        .onKeyPress(keys: [KeyEquivalent("a")]) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            selectAll()
            return .handled
        }
        .onAppear {
            store.prepare(rootURL)
            hasKeyboardFocus = true
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28 * scale, height: 28 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )

            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(rootURL.lastPathComponent)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Folder contents")
                    .font(.system(size: 9.5 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer(minLength: 8 * scale)

            switch snapshot {
            case .ready:
                let selectable = store.selectableEntryIDs(for: rootURL)
                let selected = store.selectedEntryIDs(for: rootURL)
                    .intersection(selectable)
                Text("\(selected.count)/\(selectable.count) selected")
                    .font(.system(size: 9.5 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.50))
                    .monospacedDigit()
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.75))
            case .idle, .failed:
                EmptyView()
            }
        }
        .padding(.horizontal, 15 * scale)
        .padding(.vertical, 12 * scale)
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot {
        case .idle, .scanning:
            stateView(
                symbol: "folder.badge.gearshape",
                title: "Inspecting folder…",
                detail: "Finding supported files and preparing a bounded local preview."
            ) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
            }

        case .failed(let message, _):
            stateView(
                symbol: "exclamationmark.triangle.fill",
                title: "Folder could not be inspected",
                detail: message
            ) {
                Button("Try Again") {
                    store.prepare(rootURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .ready(let result):
            manifestView(result.manifest)
        }
    }

    private func stateView<Accessory: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 9 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 25 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.56))

            Text(title)
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.90))

            Text(detail)
                .font(.system(size: 10 * scale))
                .foregroundStyle(.white.opacity(0.50))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 260 * scale)

            accessory()
                .padding(.top, 2 * scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24 * scale)
    }

    private func manifestView(_ manifest: FolderManifest) -> some View {
        let selectableIDs = store.selectableEntryIDs(for: rootURL)
        let entries = filteredEntries(
            in: manifest,
            selectableEntryIDs: selectableIDs
        )
        return VStack(alignment: .leading, spacing: 0) {
            coverageSummary(manifest)

            filterControl(manifest, selectableEntryIDs: selectableIDs)
                .padding(.horizontal, 14 * scale)
                .padding(.bottom, 9 * scale)

            if manifest.entries.isEmpty {
                emptyManifest
            } else if entries.isEmpty {
                emptyFilter
            } else {
                let selectedIDs = store.selectedEntryIDs(for: rootURL)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            FolderManifestEntryRow(
                                entry: entry,
                                isSelectable: selectableIDs.contains(entry.id),
                                isSelected: selectedIDs.contains(entry.id),
                                isFocused: focusedEntryID == entry.id
                            ) { modifiers in
                                updateSelection(
                                    for: entry,
                                    in: manifest,
                                    modifiers: modifiers
                                )
                            }

                            if entry.id != entries.last?.id {
                                Divider()
                                    .overlay(Color.white.opacity(0.07))
                                    .padding(.leading, 48 * scale)
                            }
                        }
                    }
                    .padding(.horizontal, 8 * scale)
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if manifest.wasLimited {
                scanLimitFooter(manifest)
            }
        }
    }

    private func coverageSummary(_ manifest: FolderManifest) -> some View {
        HStack(spacing: 7 * scale) {
            SummaryBadge(
                symbol: "checkmark.circle.fill",
                label: "Included",
                count: manifest.includedCount,
                color: .green
            )
            SummaryBadge(
                symbol: "minus.circle.fill",
                label: "Omitted",
                count: manifest.omittedCount,
                color: .orange
            )
            SummaryBadge(
                symbol: "xmark.circle.fill",
                label: "Skipped",
                count: manifest.skippedCount,
                color: .secondary
            )
        }
        .padding(.horizontal, 14 * scale)
        .padding(.top, 11 * scale)
        .padding(.bottom, 9 * scale)
    }

    private func filterControl(
        _ manifest: FolderManifest,
        selectableEntryIDs: Set<String>
    ) -> some View {
        HStack(spacing: 4 * scale) {
            ForEach(FolderEntryFilter.allCases) { option in
                let count = option.count(
                    in: manifest,
                    selectableEntryIDs: selectableEntryIDs
                )
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 4 * scale) {
                        Text(option.title)
                        Text("\(count)")
                            .monospacedDigit()
                            .foregroundStyle(
                                filter == option
                                    ? Color.white.opacity(0.72)
                                    : Color.white.opacity(0.35)
                            )
                    }
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundStyle(filter == option ? .white : .white.opacity(0.52))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                            .fill(filter == option ? Color.white.opacity(0.13) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.title), \(count) items")
            }
        }
        .padding(3 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var emptyManifest: some View {
        VStack(spacing: 7 * scale) {
            Image(systemName: "folder")
                .font(.system(size: 21 * scale))
                .foregroundStyle(.white.opacity(0.38))
            Text("This folder is empty")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFilter: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: filter == .supported ? "doc.badge.ellipsis" : "checkmark.circle")
                .font(.system(size: 20 * scale))
                .foregroundStyle(.white.opacity(0.36))
            Text(filter == .supported ? "No supported files" : "No skipped files")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanLimitFooter(_ manifest: FolderManifest) -> some View {
        HStack(alignment: .top, spacing: 6 * scale) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9 * scale, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1 * scale)

            Text(manifest.limitDescription ?? "The bounded local scan reached its safety limit.")
                .font(.system(size: 8.5 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(2)
        }
        .padding(.horizontal, 15 * scale)
        .padding(.vertical, 9 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06))
        .overlay(alignment: .top) {
            Divider().overlay(Color.orange.opacity(0.13))
        }
    }

    private func filteredEntries(
        in manifest: FolderManifest,
        selectableEntryIDs: Set<String>
    ) -> [FolderManifest.Entry] {
        manifest.entries.filter { entry in
            switch filter {
            case .all:
                return true
            case .supported:
                return selectableEntryIDs.contains(entry.id)
            case .skipped:
                guard !selectableEntryIDs.contains(entry.id) else { return false }
                switch entry.status {
                case .eligibleButOmitted, .skipped:
                    return true
                case .eligible, .included, .directory:
                    return false
                }
            }
        }
    }

    private func updateSelection(
        for entry: FolderManifest.Entry,
        in manifest: FolderManifest,
        modifiers: NSEvent.ModifierFlags
    ) {
        let selectableIDs = store.selectableEntryIDs(for: rootURL)
        guard selectableIDs.contains(entry.id) else { return }

        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let isAdditive = flags.contains(.command) || flags.contains(.control)
        var selectedIDs = store.selectedEntryIDs(for: rootURL)
            .intersection(selectableIDs)

        if flags.contains(.shift),
           let anchorID = selectionAnchorID,
           let anchorIndex = manifest.entries.firstIndex(where: { $0.id == anchorID }),
           let clickedIndex = manifest.entries.firstIndex(where: { $0.id == entry.id }) {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let rangeIDs = Set(
                manifest.entries[bounds]
                    .map(\.id)
                    .filter(selectableIDs.contains)
            )
            if isAdditive {
                selectedIDs.formUnion(rangeIDs)
            } else {
                selectedIDs = rangeIDs
            }
        } else if isAdditive {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
            } else {
                selectedIDs.insert(entry.id)
            }
            selectionAnchorID = entry.id
        } else if selectedIDs == Set([entry.id]) {
            selectedIDs.removeAll()
            selectionAnchorID = entry.id
        } else {
            selectedIDs = [entry.id]
            selectionAnchorID = entry.id
        }

        focusedEntryID = entry.id
        hasKeyboardFocus = true
        store.setSelectedEntryIDs(selectedIDs, for: rootURL)
    }

    private func selectAll() {
        guard case .ready(let result) = snapshot else { return }
        let selectableIDs = store.selectableEntryIDs(for: rootURL)
        guard !selectableIDs.isEmpty else { return }
        focusedEntryID = focusedEntryID.flatMap { selectableIDs.contains($0) ? $0 : nil }
            ?? result.manifest.entries.first(where: { selectableIDs.contains($0.id) })?.id
        selectionAnchorID = focusedEntryID
        store.setSelectedEntryIDs(selectableIDs, for: rootURL)
    }

    @discardableResult
    private func previewSelection() -> Bool {
        guard case .ready(let result) = snapshot else { return false }
        let selectedIDs = store.selectedEntryIDs(for: rootURL)
        let previewEntries = result.manifest.entries.filter {
            selectedIDs.contains($0.id) && canPreview($0)
        }
        guard !previewEntries.isEmpty else { return false }
        let currentIndex = focusedEntryID.flatMap { focusedID in
            previewEntries.firstIndex(where: { $0.id == focusedID })
        } ?? 0
        QuickLookController.shared.present(
            urls: previewEntries.map(\.url),
            current: currentIndex
        )
        return true
    }

    private func canPreview(_ entry: FolderManifest.Entry) -> Bool {
        guard entry.kind != .folder,
              let values = try? entry.url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey
              ]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && values.isAliasFile != true
    }
}

// MARK: - Filters and summary

private enum FolderEntryFilter: String, CaseIterable, Identifiable {
    case all
    case supported
    case skipped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:       return "All"
        case .supported: return "Supported"
        case .skipped:   return "Skipped"
        }
    }

    func count(
        in manifest: FolderManifest,
        selectableEntryIDs: Set<String>
    ) -> Int {
        switch self {
        case .all:
            return manifest.entries.count
        case .supported:
            return selectableEntryIDs.count
        case .skipped:
            return manifest.entries.reduce(into: 0) { count, entry in
                guard !selectableEntryIDs.contains(entry.id) else { return }
                switch entry.status {
                case .eligibleButOmitted, .skipped:
                    count += 1
                case .eligible, .included, .directory:
                    break
                }
            }
        }
    }
}

private struct SummaryBadge: View {
    let symbol: String
    let label: String
    let count: Int
    let color: Color

    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundStyle(color.opacity(0.88))
            Text("\(count) \(label)")
                .monospacedDigit()
        }
        .font(.system(size: 8.5 * scale, weight: .semibold))
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 4 * scale)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Entry row

private struct FolderManifestEntryRow: View {
    let entry: FolderManifest.Entry
    let isSelectable: Bool
    let isSelected: Bool
    let isFocused: Bool
    let onSelection: (NSEvent.ModifierFlags) -> Void

    @Environment(\.uiScale) private var scale
    @State private var isHovering = false

    private var canPreview: Bool {
        guard entry.kind != .folder,
              let values = try? entry.url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey
              ]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && values.isAliasFile != true
    }

    var body: some View {
        Group {
            if isSelectable {
                Button {
                    onSelection(NSEvent.modifierFlags)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .help("Select \(entry.relativePath) · Space to preview")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            } else {
                rowContent
            }
        }
        .onHover { isHovering = $0 }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 9 * scale) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(
                    isSelectable
                        ? (isSelected ? Color.accentColor : Color.white.opacity(0.32))
                        : Color.white.opacity(0.12)
                )
                .frame(width: 13 * scale, height: 26 * scale)

            Image(systemName: kindSymbol)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 26 * scale, height: 26 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 3 * scale) {
                HStack(spacing: 5 * scale) {
                    Text(entry.relativePath)
                        .font(.system(size: 10.5 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.91))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if canPreview && isSelectable && isSelected {
                        Spacer(minLength: 2 * scale)
                        Image(systemName: "eye")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundStyle(.white.opacity(isHovering ? 0.72 : 0.25))
                    }
                }

                Text(metadata)
                    .font(.system(size: 8.5 * scale))
                    .foregroundStyle(.white.opacity(0.40))
                    .lineLimit(1)

                Label(status.label, systemImage: status.symbol)
                    .font(.system(size: 8.3 * scale, weight: .semibold))
                    .foregroundStyle(status.color.opacity(0.88))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 7 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : Color.white.opacity(isSelectable && isHovering ? 0.075 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.white.opacity(0.24) : .clear,
                            lineWidth: 0.6
                        )
                )
        )
        .contentShape(Rectangle())
    }

    private var metadata: String {
        guard let bytes = entry.byteSize else { return entry.kind.title }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(entry.kind.title) · \(size)"
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .folder:   return "folder.fill"
        case .text:     return "doc.plaintext"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .data:     return "tablecells"
        case .pdf:      return "doc.richtext"
        case .richText: return "doc.text"
        case .email:    return "envelope.fill"
        case .image:    return "photo"
        case .media:    return "film"
        case .archive:  return "archivebox"
        case .unknown:  return "doc"
        }
    }

    private var status: EntryStatusPresentation {
        if isSelectable && !isSelected {
            return EntryStatusPresentation(
                label: "Deselected",
                symbol: "circle",
                color: .secondary
            )
        }
        switch entry.status {
        case .eligible:
            return EntryStatusPresentation(
                label: "Preparing",
                symbol: "clock.fill",
                color: .blue
            )
        case .included:
            return EntryStatusPresentation(
                label: entry.isPartial ? "Included (partial)" : "Included",
                symbol: "checkmark.circle.fill",
                color: .green
            )
        case .eligibleButOmitted:
            return EntryStatusPresentation(
                label: "Omitted · \(entry.omissionReason?.label ?? "Context limit")",
                symbol: "minus.circle.fill",
                color: .orange
            )
        case .skipped(let reason):
            return EntryStatusPresentation(
                label: "Skipped · \(reason.label)",
                symbol: "xmark.circle.fill",
                color: .secondary
            )
        case .directory:
            return EntryStatusPresentation(
                label: "Folder",
                symbol: "folder.fill",
                color: .secondary
            )
        }
    }
}

private struct EntryStatusPresentation {
    let label: String
    let symbol: String
    let color: Color
}
