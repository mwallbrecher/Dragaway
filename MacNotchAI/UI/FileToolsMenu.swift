import SwiftUI
import AppKit

// MARK: - File tools menu button
//
// The ••• control on a file pill. Opens a SwiftUI Menu of type-gated FileTool items
// (FileTool.tools(for:sessionFiles:)). Item actions run the FileTools engine and
// confirm the result the macOS-native way:
//   • new outputs (pdf→txt, stitch, image)  → revealed in Finder
//   • rename / move                          → session URL remapped (pill updates live)
//   • failures                               → NSAlert
// Dialogs that need input (rename, image options, move) use NSAlert / NSOpenPanel —
// proven to present correctly from the floating overlay panel (SwiftUI .alert can fail
// to find a key window here). See tasks/lessons.md.

struct FileToolsButton: View {
    let fileURL: URL
    /// Compact = small dark corner badge (icon-only multi-file pills). Default =
    /// 22×22 glass circle matching ShareButton (single-file pill).
    var compact: Bool = false
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale
    @State private var isHovered = false

    /// All files in the current session (primary + added), for Stitch gating.
    private var sessionFiles: [URL] {
        guard let primary = vm.stage.fileURL else { return [fileURL] }
        return [primary] + vm.additionalFileURLs
    }

    private var tools: [FileTool] { FileTool.tools(for: fileURL, sessionFiles: sessionFiles) }

    var body: some View {
        Menu {
            ForEach(tools) { tool in
                if tool == .pdfToText || tool == .resizeImage {
                    Divider()
                }
                Button { perform(tool) } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                }
            }

            Divider()

            // Native macOS share sheet (NSSharingServicePicker) via ShareLink —
            // full service list + extensions, not a hand-rolled subset.
            ShareLink(item: fileURL) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        } label: {
            if compact {
                Image(systemName: "ellipsis")
                    .font(.system(size: 6 * scale, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 13 * scale, height: 13 * scale)
                    .background(Circle().fill(Color(white: 0.20).opacity(0.95)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 8 * scale, weight: .bold))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.60))
                    .frame(width: 22 * scale, height: 22 * scale)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                            .overlay(
                                Circle().strokeBorder(
                                    Color.white.opacity(isHovered ? 0.22 : 0.12),
                                    lineWidth: 0.5
                                )
                            )
                    )
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("File tools")
    }

    // MARK: - Dispatch

    private func perform(_ tool: FileTool) {
        switch tool {
        case .reveal:
            FileTools.revealInFinder([fileURL])

        case .rename:
            guard let newName = Self.promptRename(current: fileURL) else { return }
            run {
                let newURL = try FileTools.rename(fileURL, to: newName)
                vm.remapSessionURL(from: fileURL, to: newURL)
                return nil   // file stays in place — no reveal
            }

        case .move:
            guard let folder = Self.promptMoveFolder(for: fileURL) else { return }
            run {
                let newURL = try FileTools.move(fileURL, to: folder)
                vm.remapSessionURL(from: fileURL, to: newURL)
                return newURL   // reveal so the user sees where it landed
            }

        case .pdfToText:
            run { try FileTools.exportPDFText(fileURL) }

        case .stitchPDFs:
            run { try FileTools.stitchPDFs(sessionFiles) }

        case .resizeImage:
            guard let opts = Self.promptImageOptions() else { return }
            run { try FileTools.resizeAndRecompressImage(
                fileURL, maxDimension: opts.maxDimension, quality: opts.quality) }
        }
    }

    /// Runs a throwing op on the main thread. A returned URL is revealed in Finder;
    /// `nil` means "no output to reveal". Failures surface as an NSAlert.
    private func run(_ op: () throws -> URL?) {
        do {
            if let output = try op() {
                FileTools.revealInFinder([output])
            }
        } catch {
            Self.presentError(error)
        }
    }

    // MARK: - AppKit dialogs

    /// Rename prompt prefilled with the current base name (no extension).
    private static func promptRename(current url: URL) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename file"
        alert.informativeText = "Enter a new name for “\(url.lastPathComponent)”. "
            + "The extension is kept automatically."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = url.deletingPathExtension().lastPathComponent
        field.font = .systemFont(ofSize: 13)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Folder picker for "Move to…". Defaults to the file's current directory.
    private static func promptMoveFolder(for url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = "Choose a folder to move “\(url.lastPathComponent)” into."
        panel.directoryURL = url.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    struct ImageOptions { let maxDimension: CGFloat?; let quality: CGFloat }

    /// Max-dimension + JPEG-quality picker for image resize/compress.
    private static func promptImageOptions() -> ImageOptions? {
        let alert = NSAlert()
        alert.messageText = "Resize / Compress image"
        alert.informativeText = "Exports a new JPEG next to the original."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 64))

        let sizeLabel = NSTextField(labelWithString: "Max size")
        sizeLabel.frame = NSRect(x: 0, y: 38, width: 70, height: 20)
        container.addSubview(sizeLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 78, y: 34, width: 182, height: 26))
        popup.addItems(withTitles: ["Original size", "2048 px", "1024 px", "512 px"])
        popup.selectItem(at: 2)   // default 1024 px
        container.addSubview(popup)

        let qLabel = NSTextField(labelWithString: "Quality")
        qLabel.frame = NSRect(x: 0, y: 4, width: 70, height: 20)
        container.addSubview(qLabel)

        let slider = NSSlider(value: 0.7, minValue: 0.3, maxValue: 1.0,
                              target: nil, action: nil)
        slider.frame = NSRect(x: 78, y: 2, width: 182, height: 22)
        container.addSubview(slider)

        alert.accessoryView = container
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let maxDim: CGFloat?
        switch popup.indexOfSelectedItem {
        case 1:  maxDim = 2048
        case 2:  maxDim = 1024
        case 3:  maxDim = 512
        default: maxDim = nil   // Original size
        }
        return ImageOptions(maxDimension: maxDim, quality: CGFloat(slider.doubleValue))
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t complete that"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
