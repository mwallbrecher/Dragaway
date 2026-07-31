# Dragaway v1.1.5

**Understand whole folders and richer websites — with transparent local preparation.**

## What's new

- **Drop complete folders.** Dragaway can now inspect a Finder folder, show its contents, and answer
  questions such as **What Does This Folder Do?** in one normal AI request. The local scan is bounded
  by depth, time, file count, and source size; it never follows symlinks and skips hidden/generated
  directories plus known key and secret files.
- **Control the folder context.** The preview clearly separates supported, omitted, and skipped files.
  Select exactly which supported files may enter the request with Finder-style click,
  Command/Control multi-select, Shift ranges, Command-A, and Space for Quick Look. Files are prepared
  once per session, so changing the selection does not parse them again.
- **More complete website text.** Safari tabs and URL drops now run a structured Mozilla Readability
  pass instead of relying on raw HTML stripping. JavaScript-heavy pages get a bounded, cookie-free,
  ephemeral rendered-page fallback with images, media, fonts, popups, and unrelated navigation
  blocked. If an action is selected immediately, it waits for the same background preparation.
- **A cleaner native model picker.** Enabled models are grouped as provider → family/generation →
  exact model, making large live BYOK catalogues much easier to navigate. Dragaway Free remains one
  fixed, simple option.
- **More reliable asynchronous sessions.** Dragaway now rejects overlapping AI turns, cancels stale
  work when a session changes, keeps pending website preparation attached across renames, and avoids
  applying late results to the wrong file or restored folder session.

## Privacy and limits

Website and folder preparation happens locally. No document or folder content is sent to an AI
provider until you start an AI action. The folder preview shows the actual coverage; unsupported,
oversized, excluded, or safety-limited files are not presented as analysed. Website extraction may
contact the dropped website and run its first-party JavaScript in an isolated ephemeral WebKit view
when static HTML is insufficient.

## Install / update

Installed copies update in place via **Check for Updates…**, or download **Dragaway-1.1.5.dmg** below.
The build is signed with a Developer ID certificate and notarized by Apple, so it opens normally
without a Gatekeeper workaround.
