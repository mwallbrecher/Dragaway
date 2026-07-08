# Dragaway v1.1.1

**Your daily tools, one drag away.** This release is a rename and a reframe: the app formerly known as AI Drop is now **Dragaway** — because it's grown well past AI actions into a universal drag-router. v1.1 adds a second drag mode (the radial launcher), lets you drag *anything* (not just files), streams AI replies live, and ships an in-app tutorial, auto-updater, and a much smarter suggestion engine.

## Highlights in v.1.1.1

- Dragaway now supports assets beyond just files. You can drag. and drop literally anything. Files, Safari tabs, Selections and more
- Launch your current clipboard directly to Dragaway session with ⌃⌘N
- You can now add taken screenshots automatically in a Session.
- Dragaway can now be updated natively without a need to reinstalling the .dmg.

---

### Renamed: AI Drop → Dragaway
Same app, same data, new name and identity — reflecting a tool for *all* your daily drags, not just AI. All user-facing text, the app display name, and the release/update infrastructure now say Dragaway.

### Radial launcher — a second drag mode (new)
Hold **⇧ Shift** as you start dragging a file and a wheel of your **favorite apps** fans out around the cursor. Flick toward a wedge and release to open the file there — no target to aim for, no menu to click.
- A **Start Session** slot (top of the wheel) routes the file into the AI card instead of an app — toggle with **Show AI Drop in Launcher**.
- The notch pill and the radial launcher are independently configurable in **Drag Hotkeys**: give each its own key, switch either off, or leave both keyless so a single drag shows both together.
- When both appear, dragging toward the notch hands the file to the pill; flicking to a wedge launches the app — the wheel only releases its selection as you approach the pill, so long outward flicks still launch reliably.
- A background failsafe guarantees the wheel can never get stuck capturing clicks if a drag ends unexpectedly.

### Drag anything — not just files (new)
The pill now wakes for **text selections, web links, and images** dragged from anywhere — not only Finder. Drag an image straight out of a Google Images results page, or a paragraph of selected text from any app, and it opens in a session exactly like a file (captured to a small local file behind the scenes). Radial launching stays file-only, since apps open files, not raw selections.

### Streaming AI replies (new)
Answers now appear **live, token by token**, instead of popping in all at once when the request finishes — across Groq, OpenAI, Gemini, Claude, and Ollama. (Fixed a subtle bug where response compression was silently buffering the whole stream until completion; requests now request uncompressed event streams so deltas render as they arrive.)

### Clipboard & screenshot → session (new)
- **⌃⌘N** opens a new session from whatever's on the clipboard right now — copied files, text, a link, or an image (including a screenshot copied with ⌃⇧⌘4).
- **"Open new screenshots in a session"** (Settings → Clipboard & Capture): every ⇧⌘4 / ⇧⌘5 screenshot opens straight into Dragaway. Choose **Instant** (skips the floating thumbnail so the file saves immediately) or **Keep the thumbnail** (session opens after the standard ~5s preview).

### Interactive tutorial (new)
A real, hands-on first-run tour — not just slides. Each step waits for the actual action (drop a file, drop something that isn't a file, Tab-cycle the tabs, launch a favorite app, trigger the radial wheel, use a clipboard hotkey) and checks itself off automatically. Drag samples are built into the tutorial window itself, so there's no need to go hunting for a file or open a browser. Skippable at every step; restart anytime from **Settings → Help**.

### Smarter, deeper suggestions (new)
The suggested-actions catalog grew from 17 to 36, with dedicated actions for CSVs (Summarise Table, Show Trends, Find Outliers, Suggest Charts, Make a Report), images (Analyse UI, Design Reference, Rebuild as HTML/CSS), everyday text (Draft Email Reply, Extract To-Dos, Extract Names & Contacts, Proofread & Fix), and notes (5-Slide Outline, LinkedIn Post, Turn into a Brief). The 6-chip limit stays — a local, on-device **frecency engine** learns which actions you actually use per file type and promotes them, alongside content signals (CSV structure, email/to-do/notes detection) and filename keywords (invoice, screenshot, resume…). All fully local — nothing is sent anywhere to make a suggestion.

### Session search (new)
**Search Sessions…** in the menu bar full-text searches your session history — filenames, prompts, and answers. History depth raised from 10 to 25 sessions.

### Send Feedback (new)
**Settings → Send Feedback** — pick Bug / Idea / Feedback / Question / Other, write a note, send. Falls back to a prefilled email if the network is unreachable.

### Auto-update (new)
Dragaway can now update itself in place via Sparkle — a background check finds a new version and offers **Install & Relaunch**, no manual re-download. (First hop from v1.0-beta is still a manual install; every release after this one updates automatically.)

### Real file icons
A dropped file now shows its actual Quick Look thumbnail — the image itself, a PDF's first page, a video's poster frame — instead of a generic type icon.

### Polish & fixes
- The dropped-file pill is now a flat, slightly-transparent black surface (matching the radial launcher) instead of frosted glass, and renders identically in light and dark mode.
- Close and minimize buttons have larger, more reliable click targets.
- Removed a stray blue "+N" overflow badge that crowded the header with 3+ files attached.
- Removed "Continue in [Provider]" from results — launching directly into an app (via the Open-in row or the radial launcher) replaces it.
- The action card now appears **instantly** on drop; the content peek that fine-tunes suggestions now runs in the background instead of blocking the first paint.
- Script commands now shell-quote substituted file paths, so filenames with spaces or special characters no longer break a script.

## Install

1. Download **Dragaway-1.1.dmg** below.
2. Open the DMG and drag the app into **Applications**.
3. Launch it — it lives in your menu bar (✦ icon). On first launch, grant Accessibility (for drag detection) and pick your AI provider.
4. From here on, updates arrive in place — no more manual downloads.

> This DMG is signed with a Developer ID certificate and **notarized by Apple**, so it opens normally — no Gatekeeper workaround needed.
