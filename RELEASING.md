# Releasing Dragaway — command sequence

Run from the repo root (`~/development/MacNotchAI`). Example below releases **1.1.1**
(build 4) — substitute your version everywhere.

## 0 · One-time setup (skip if already done)

```bash
# Export the Sparkle EdDSA private key to a file (bypasses flaky Keychain access).
# release.sh picks it up automatically from this exact path.
"$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*Sparkle*' | head -1)" \
  -x ~/.dragaway_sparkle_key
```

Notarytool credentials (`AIDrop-Notary`) already live in your Keychain — leave the
profile name as-is.

## 1 · Bump the version

`MARKETING_VERSION` = what users see. `CURRENT_PROJECT_VERSION` = Sparkle's compare
number — **must increase every release** or auto-update won't trigger.

```bash
sed -i '' 's/MARKETING_VERSION = 1.1;/MARKETING_VERSION = 1.1.1;/g' MacNotchAI.xcodeproj/project.pbxproj
sed -i '' 's/CURRENT_PROJECT_VERSION = 3;/CURRENT_PROJECT_VERSION = 4;/g' MacNotchAI.xcodeproj/project.pbxproj
```

## 2 · Release notes + README

Write `RELEASE_NOTES_v1.1.1.md` (what changed) and add/refresh the
"What's New" section in `README.md`.

## 3 · Sanity build

```bash
xcodebuild -scheme MacNotchAI -configuration Debug build CODE_SIGNING_ALLOWED=NO | grep -E "BUILD (SUCCEEDED|FAILED)"
```

## 4 · Commit, push, tag

```bash
git add -A && git commit -m "feat: v1.1.1 — <summary>"
git push origin main
git tag -a v1.1.1 -m "Dragaway v1.1.1" && git push origin v1.1.1
```

## 5 · Build the signed, notarized DMG (+ signed appcast)

```bash
scripts/release.sh
```

Does: archive → Developer-ID export → DMG → Apple notarization → staple →
regenerates `appcast.xml` signed with `~/.dragaway_sparkle_key`.
**It prints a loud ⚠ warning if the appcast ended up unsigned — do not ship then.**

Verify:

```bash
grep -c edSignature appcast.xml   # MUST print 1 (or the number of releases listed)
```

## 6 · Publish the GitHub release (DMG attached)

```bash
gh release create v1.1.1 build/Dragaway-1.1.1.dmg \
  --repo mwallbrecher/Dragaway \
  --title "Dragaway v1.1.1" \
  --notes-file RELEASE_NOTES_v1.1.1.md
```

## 7 · Ship the update feed (LAST — this flips the switch)

```bash
git add appcast.xml && git commit -m "chore: appcast v1.1.1" && git push origin main
```

Installed apps see the update within ~6 h, or instantly via **Check for Updates…**.

## 8 · Verify

```bash
gh release view v1.1.1 --repo mwallbrecher/Dragaway --json assets,isPrerelease
```

Then on your Mac: run the PREVIOUS version → menu bar → Check for Updates… →
should offer the new one → Install & Relaunch.

---

### Order matters
DMG upload (6) **before** appcast push (7): the appcast points at the release asset —
push the feed first and updaters get a 404.

### Gotchas
- **Bundle ID changed in v1.1.1** (`com.wallbrecher.dragaway`): v1.1-and-earlier
  installs can NOT auto-update across a bundle-id change — one manual install, then
  auto-updates work forever. Never change the bundle id again.
- `AIDrop-Notary` is the Keychain profile name for notarytool — renaming it breaks step 5.
- If `generate_appcast` isn't found: open Xcode once so the Sparkle package resolves,
  or set `SPARKLE_BIN=/path/to/generate_appcast`.
