import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - File tools runner
//
// Dispatch + native dialogs for the file-utility actions (FileTool). These used to
// live behind the ••• menu on the file pill; that control is now a plain Share button
// and the utilities surface as chips in the chips-stage "Utilities" tab. The tab calls
// `FileToolActions.perform(_:fileURL:sessionFiles:)`; results confirm the macOS-native way:
//   • new outputs (pdf→txt, stitch, image)  → revealed in Finder
//   • rename / move                          → session URL remapped (pill updates live)
//   • failures                               → NSAlert
// Dialogs that need input (rename, image options, move) use NSAlert / NSOpenPanel —
// proven to present correctly from the floating overlay panel (SwiftUI .alert can fail
// to find a key window here). See tasks/lessons.md.

@MainActor
enum FileToolActions {

    /// Stitch needs ≥ 2 PDFs in the session.
    static func stitchEnabled(sessionFiles: [URL]) -> Bool {
        sessionFiles.filter { $0.pathExtension.lowercased() == "pdf" }.count >= 2
    }

    /// The utility actions to OFFER for `url`, given the session. Same as
    /// `FileTool.tools` but with Stitch dropped when it can't run yet (chips have no
    /// disabled state, so we hide it rather than show a dead row). The chips-stage row
    /// count derives from this exact list, so the window height stays in sync.
    static func utilityTools(for url: URL, sessionFiles: [URL]) -> [FileTool] {
        var list = FileTool.tools(for: url, sessionFiles: sessionFiles)
        if !stitchEnabled(sessionFiles: sessionFiles) {
            list.removeAll { $0 == .stitchPDFs }
        }
        return list
    }

    // MARK: - Dispatch

    static func perform(_ tool: FileTool, fileURL: URL, sessionFiles: [URL]) {
        let vm = OverlayViewModel.shared
        switch tool {
        case .reveal:
            FileTools.revealInFinder([fileURL])

        case .rename:
            guard let newName = promptRename(current: fileURL) else { return }
            run {
                let newURL = try FileTools.rename(fileURL, to: newName)
                vm.remapSessionURL(from: fileURL, to: newURL)
                return nil   // file stays in place — no reveal
            }

        case .move:
            guard let folder = promptMoveFolder(for: fileURL) else { return }
            run {
                let newURL = try FileTools.move(fileURL, to: folder)
                vm.remapSessionURL(from: fileURL, to: newURL)
                return newURL   // reveal so the user sees where it landed
            }

        case .pdfToText:
            runFile(tool, original: fileURL) { try FileTools.exportPDFText(fileURL) }
        case .pdfToMarkdown:
            runFile(tool, original: fileURL) { try FileTools.exportPDFMarkdown(fileURL) }
        case .pdfToDocx:
            runFile(tool, original: fileURL) { try FileTools.exportPDFDocx(fileURL) }

        case .pdfSplit:
            runFile(tool, original: fileURL) { try FileTools.splitPDF(fileURL) }

        case .pdfToImages:
            runFile(tool, original: fileURL) { try FileTools.pdfToImages(fileURL) }

        case .stitchPDFs:
            runFile(tool, original: fileURL) { try FileTools.stitchPDFs(sessionFiles) }

        case .convertToJPEG:
            runFile(tool, original: fileURL) { try FileTools.convertImage(fileURL, to: .jpeg, ext: "jpg") }

        case .stripEXIF:
            runFile(tool, original: fileURL) { try FileTools.stripImageMetadata(fileURL) }

        case .imagesToPDF:
            runFile(tool, original: fileURL) { try FileTools.imagesToPDF(sessionFiles) }

        case .resizeImage:
            guard let opts = promptImageOptions() else { return }
            runFile(tool, original: fileURL) { try FileTools.resizeAndRecompressImage(
                fileURL, maxDimension: opts.maxDimension, quality: opts.quality) }

        case .prettyJSON:
            runFile(tool, original: fileURL) { try FileTools.prettyPrintJSON(fileURL) }

        case .compress:
            runFile(tool, original: fileURL) { try FileTools.compress(fileURL) }

        // Text / code / data (batch 3) — synchronous, instant.
        case .sortLines:
            runFile(tool, original: fileURL) { try FileTools.sortLines(fileURL) }
        case .dedupeLines:
            runFile(tool, original: fileURL) { try FileTools.dedupeLines(fileURL) }
        case .minifyJSON:
            runFile(tool, original: fileURL) { try FileTools.minifyJSON(fileURL) }
        case .csvToJSON:
            runFile(tool, original: fileURL) { try FileTools.csvToJSON(fileURL) }
        case .jsonToCSV:
            runFile(tool, original: fileURL) { try FileTools.jsonToCSV(fileURL) }
        case .base64Encode:
            runFile(tool, original: fileURL) { try FileTools.base64Encode(fileURL) }
        case .base64Decode:
            runFile(tool, original: fileURL) { try FileTools.base64Decode(fileURL) }

        // INFO ops — produce a value (not a file): show it with a Copy button.
        case .countText:
            runInfo(title: "Lines / Words / Characters") { try FileTools.countStats(fileURL) }
        case .hashSHA256:
            runInfo(title: "SHA-256 — \(fileURL.lastPathComponent)") { try FileTools.sha256(fileURL) }

        // Async ops (media + Markdown→PDF) must go through `performAsync`, not here.
        case .extractAudio, .transcribe, .videoToGIF, .extractFrame, .compressVideo,
             .muteVideo, .convertToMP4, .convertToMOV, .convertToM4A, .markdownToPDF, .docxToPDF:
            assertionFailure("async tool \(tool) must be dispatched via performAsync")
        }
    }

    /// Async dispatch for the media tools (AVFoundation / Speech). Reveals the sibling
    /// output in Finder on success; failures surface as an NSAlert. The caller (chips
    /// Utilities tab) shows a per-row spinner for the duration.
    static func performAsync(_ tool: FileTool, fileURL: URL, sessionFiles: [URL]) async {
        do {
            let output: URL?
            switch tool {
            case .extractAudio:  output = try await MediaTools.extractAudio(fileURL)
            case .transcribe:    output = try await MediaTools.transcribe(fileURL)
            case .videoToGIF:    output = try await MediaTools.videoToGIF(fileURL)
            case .extractFrame:  output = try await MediaTools.extractFrame(fileURL)
            case .compressVideo: output = try await MediaTools.compressVideo(fileURL)
            case .muteVideo:     output = try await MediaTools.muteVideo(fileURL)
            case .convertToMP4:  output = try await MediaTools.convertVideo(fileURL, to: .mp4, ext: "mp4")
            case .convertToMOV:  output = try await MediaTools.convertVideo(fileURL, to: .mov, ext: "mov")
            case .convertToM4A:  output = try await MediaTools.convertAudio(fileURL)
            case .markdownToPDF: output = try await MarkdownPDF.export(fileURL)
            case .docxToPDF:     output = try await MarkdownPDF.exportDocxToPDF(fileURL)
            default:             return   // non-async tools go through `perform`
            }
            if let output {
                presentFileResult(tool: tool, original: fileURL,
                                  output: relocate(output, original: fileURL))
            }
        } catch {
            presentError(error)
        }
    }

    /// Runs a throwing op on the main thread. A returned URL is revealed in Finder;
    /// `nil` means "no output to reveal". Failures surface as an NSAlert.
    private static func run(_ op: () throws -> URL?) {
        do {
            if let output = try op() {
                FileTools.revealInFinder([output])
            }
        } catch {
            presentError(error)
        }
    }

    /// Runs a file-PRODUCING op, then advances to the utility result stage
    /// (Stage.fileResult) — Finder reveal + a side-by-side details card (output vs the
    /// `original` source, with a size delta). For multi-file ops (stitch / images→PDF)
    /// pass the primary file as `original`. Failures surface as an NSAlert.
    private static func runFile(_ tool: FileTool, original: URL, _ op: () throws -> URL) {
        do { presentFileResult(tool: tool, original: original, output: relocate(try op(), original: original)) }
        catch { presentError(error) }
    }

    // MARK: - Output directory

    /// The effective output directory for `original` this session, or `nil` = "next to the
    /// original" (the historical default). Session override wins over the persisted store.
    static func effectiveOutputDir(for original: URL) -> URL? {
        switch OverlayViewModel.shared.sessionOutputOverride {
        case .sibling:          return nil                 // × reset → force same folder
        case .folder(let url):  return url
        case .inherit:          return OutputDirectoryStore.shared.resolved(
                                          for: FileInspector.category(for: original))
        }
    }

    /// Move a freshly-produced output into the configured directory (best-effort). Works
    /// for single files AND the folder outputs of split / pdf→images. Returns the produced
    /// file unchanged when no directory is set, it's already there, or the move fails.
    private static func relocate(_ output: URL, original: URL) -> URL {
        guard let dir = effectiveOutputDir(for: original) else { return output }
        if output.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            return output
        }
        return (try? FileTools.move(output, to: dir)) ?? output
    }

    /// Reveals `output` in Finder, then transitions the model to `.fileResult`. The
    /// stage write is deferred one runloop tick and wrapped in `withAnimation` — writing
    /// `stage` synchronously inside a layout pass re-enters the constraint solver and
    /// aborts (the stage-write invariant). Shared by the sync and async dispatch paths.
    static func presentFileResult(tool: FileTool, original: URL, output: URL) {
        FileTools.revealInFinder([output])
        let vm = OverlayViewModel.shared
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                vm.stage = .fileResult(original: original, output: output, tool: tool)
            }
        }
    }

    /// Runs an op that returns a STRING (checksum, counts) and shows it in an alert with
    /// a Copy button instead of writing a file. Failures surface as an NSAlert.
    private static func runInfo(title: String, _ op: () throws -> String) {
        do { presentInfo(title: title, value: try op()) }
        catch { presentError(error) }
    }

    private static func presentInfo(title: String, value: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = value
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
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
