# AI Drop v1.0 (beta)

Your tools and AI — one drag away. The first 1.0 beta builds on v0.9.9 with a runnable **Scripts** tab, **document conversions** (PDF ⇄ Markdown, PDF ⇄ Word), an **output-folder** control for everything you create, a top-to-bottom **Liquid Glass** redesign, and a stack of interaction polish — drop-to-focus, keyboard tab-cycling, and reorderable rows.

## Highlights

### Scripts — your own commands, one drag away (new)
A new fifth tab in the action card. Save commands you run all the time — `npm run dev`, `git diff`, `git status`, `code .`, anything — and fire them against the dropped file's folder.
- Run **in Terminal** (opens Terminal.app) or **captured in-app** (output shown inline).
- Placeholders expand automatically: `{file}`, `{dir}`, `{name}`, `{root}` (git root).
- Optional **Run in git root** per script.
- **Drag to reorder**, add/edit/remove in **Settings → Scripts**.
- Scripts are user-authored and only ever run when you tap them — nothing runs on its own.

### Document conversions (new)
Convert files locally, no upload, no API key:
- **PDF → Markdown** and **Markdown → PDF**
- **PDF → Word (.docx)** and **Word (.docx) → PDF**

### Choose where new files land (new)
A persistent **Output Directory** setting plus a per-session override, so converted/produced files go exactly where you want.
- Inline, editable path field right in the **Utilities** tab — type a path, or click the folder button to pick one in Finder.
- Manage the default in **Settings → Output Directory**; reset to "next to the original" any time.

### Liquid Glass redesign
The whole surface now uses real **Liquid Glass** — on macOS 26 it renders with the system `glassEffect`, with a faithful custom blur fallback on earlier macOS.
- A dark-top → clear-bottom gradient gives the card real depth instead of a flat frost.
- Applied consistently across the card, the buttons, and the **"Drop file here"** pill.
- The window no longer greys out when it isn't the focused app.

### Smarter suggestions
Suggested prompts are now reordered using lightweight **on-device heuristics** that peek at the file's content — still fully local, nothing leaves your Mac.

### Tab bar + keyboard
- The three AI tabs are grouped together; the **active** icon is larger while the others step back.
- A single caption above the row updates to whatever tab you hover — AI Suggestions / AI History / AI Customs / Utilities / Scripts — with a clean fade on switch.
- **Tab** / **Shift+Tab** cycle through the tabs.

### Drop-to-focus
Drop a file and the card **takes focus immediately** — start typing a prompt or use Tab right away, no click needed. (The pill still appears non-intrusively mid-drag so it never cancels your drag.)

### Polish
- **Clear History** buttons (with an "are you sure?" confirm) on prompt history, clipboard history, and session history.
- Clipboard picker corner-rounding fix + a red **Clear History** button.
- The output-path / directory tag is now reliably clickable and styled like a real text field.
- **Drag to reorder** utility rows as well as scripts.
- Settings now opens offset to the side of the card instead of behind it.
- A **→** button restores the last file-utility result after you go back.

## Install

1. Download **AIDrop-1.0.dmg** below.
2. Open the DMG and drag **MacNotchAI.app** into **Applications**.
3. Launch it — it lives in your menu bar (✦ icon). On first launch, grant Accessibility (for drag detection) and pick your AI provider.

> This DMG is signed with a Developer ID certificate and **notarized by Apple**, so it opens normally — no Gatekeeper workaround needed.

> Beta: please report anything rough. Bring your own AI key; all file conversions and scripts run entirely on your Mac.
