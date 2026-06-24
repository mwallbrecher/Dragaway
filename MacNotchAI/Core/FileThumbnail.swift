import AppKit
import QuickLookThumbnailing

/// Resolves the *actual* icon for a file — a real Quick Look content thumbnail
/// (the image itself, a PDF's first page, a video poster frame, …) rather than the
/// generic kind/placeholder icon `NSWorkspace.icon(forFile:)` returns for most
/// document types. This matches what Finder shows in icon view.
enum FileThumbnail {

    /// Load the best image for `url` at `size` points.
    ///
    /// `onImage` is invoked on the main actor, possibly **twice**:
    ///   1. immediately with the Finder type icon (so the pill is never empty), then
    ///   2. with the high-fidelity Quick Look thumbnail once it's generated.
    ///
    /// QuickLook caches internally, so re-requesting the same file is cheap. When a
    /// file has no content preview (plain folder, unknown type) step 2 simply returns
    /// the same icon, so there's no regression versus the old behaviour.
    @MainActor
    static func load(for url: URL, size: CGFloat, onImage: @escaping (NSImage) -> Void) {
        // 1 — instant fallback so the slot is filled while QuickLook works.
        onImage(NSWorkspace.shared.icon(forFile: url.path))

        // 2 — real thumbnail. Use the screen scale so it's crisp on Retina.
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: screenScale,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            Task { @MainActor in onImage(image) }
        }
    }
}
