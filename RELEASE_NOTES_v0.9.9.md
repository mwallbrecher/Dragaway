# AI Drop v0.9.9

Your tools and AI — one drag away. This release turns AI Drop from an AI-only helper into a full drag-router: favorite-app launching, a large local file toolbox (no uploads), video/audio support, Quick Look, a result view for file operations, and a system-wide clipboard history.

## Highlights

### Favorite apps — "Open in" row
Pick your go-to apps in **Settings → Favorite Tools**, then open any dropped file in them with one click — or press **⌥1 … ⌥9**. The numbered row appears on both the action card and the result card.

### Clipboard history (new)
- Keeps your **last 20** clipboard items: text, images, and files.
- Press **⌃⌘V** for a quick picker of the **last 10** — tap a number key (1–9, 0 for the tenth) or click to copy it back, then **⌘V** to paste.
- The full 20 live in the menu bar under **Clipboard History**; ⌥-click a row to remove just that one, or Clear to wipe all.
- Password-manager items (anything marked sensitive/concealed) are **never** captured.
- History **survives a restart**, and the whole feature can be turned off with **Track Clipboard**.
- ⌃⌘V is a system hotkey that's consumed before it reaches the app underneath — no Accessibility permission required, and copy-only (we never synthesize keystrokes).

### A local file toolbox — no uploads, no API key
Every file pill's **•••** menu now runs a large set of pure-Apple-framework tools entirely on your Mac:
- **PDF** — Export as Text · Split into Pages · Pages to Images · Stitch PDFs
- **Images** — Convert to JPEG · Convert to PDF · Resize / Compress · Remove Metadata (EXIF)
- **Video & audio** — Extract Audio · Transcribe · Convert to GIF · Extract Frame · Compress Video · Remove Audio · Convert to MP4 / MOV / M4A
- **Text, code & data** — Sort Lines · Remove Duplicate Lines · Count Lines / Words · SHA-256 Checksum · Base64 Encode / Decode · Pretty-Print / Minify JSON · CSV ⇄ JSON
- **Any file** — Compress to .zip · Show in Finder · Rename · Move to…

### Video & audio are first-class
Drop a video or audio file even with **no AI provider configured** — you still get the full utility toolbox and the Open-in row.

### Quick Look on click
Click a file pill to preview it full-size (the familiar spacebar preview): images, PDFs, video, audio, text, and code.

### Result view for file tools
When a tool creates a new file, AI Drop shows a result card placing the **new file next to the original**, with the size saved (e.g. "73 % smaller"), dimensions / pages / duration, and one-tap **Reveal in Finder** / **Quick Look**.

### Also
- New app icon.
- Assorted animation, centering, and hit-target polish.

## Install

1. Download **AIDrop-0.9.9.dmg** below.
2. Open the DMG and drag **MacNotchAI.app** into **Applications**.
3. Launch it — it lives in your menu bar (✦ icon). On first launch, grant Accessibility (for drag detection) and pick your AI provider.

> This DMG is signed with a Developer ID certificate and **notarized by Apple**, so it opens normally — no Gatekeeper workaround needed.
