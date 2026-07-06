# Auto-update (Sparkle) — one-time setup

Dragaway updates itself via **Sparkle 2**: a background check finds a newer build in the
appcast feed, downloads the notarized DMG, verifies its signature, and installs it on
relaunch. Users click **Check for Updates…** (menu bar) or just get the prompt — no
manual re-download.

The code is already wired ([UpdaterController.swift](MacNotchAI/Core/UpdaterController.swift),
menu item, `release.sh`). Three one-time steps remain — they need your machine, a secret
key, and the GitHub repo, so they can't be scripted blind.

## 1. Add the Sparkle package (Xcode, ~30s)

1. Xcode → **File → Add Package Dependencies…**
2. URL: `https://github.com/sparkle-project/Sparkle`
3. Dependency Rule: **Up to Next Major**, `2.0.0`.
4. Add the **Sparkle** library product to the **MacNotchAI** app target (NOT the
   AddToAIDrop extension).
5. Build (⌘B) — the `import Sparkle` code compiles now.

## 2. Generate the signing keys (once, ever)

Sparkle signs every update with an EdDSA key so a hijacked feed can't push malware.

```bash
# Path is inside the resolved package; adjust the DerivedData hash if needed.
"$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*/Sparkle/*' | head -1)"
```

- This stores the **private key in your login Keychain** (never commit it, never export it).
- It prints a **public key** (base64). Paste it into the build setting
  `INFOPLIST_KEY_SUPublicEDKey` — currently the placeholder `PASTE_SPARKLE_PUBLIC_KEY_HERE`
  in `MacNotchAI.xcodeproj/project.pbxproj` (both the app's Debug + Release configs).

> Back up the private key (`generate_keys -x private-key.pem`, store somewhere safe like a
> password manager). If you lose it you can never sign updates for existing installs again.

## 3. Feed + hosting (already chosen: GitHub)

- **Feed URL** (already set as `INFOPLIST_KEY_SUFeedURL`):
  `https://raw.githubusercontent.com/mwallbrecher/Dragaway/main/appcast.xml`
- **DMGs**: hosted as assets on each GitHub Release (`v1.1`, `v1.2`, …).
- `appcast.xml` lives at the repo root on `main`.

## Shipping an update (every release)

```bash
scripts/release.sh                 # archives, notarizes, staples, signs, writes appcast.xml
```

Then:
1. **Upload** `build/Dragaway-<version>.dmg` as an asset on the GitHub release tagged
   `v<version>` (the appcast's enclosure URL points there).
2. **Commit & push** the regenerated `appcast.xml` to `main`.

Installed apps pick it up within ~6h, or immediately via **Check for Updates…**.

## Notes

- App is **not sandboxed**, so `SPUStandardUpdaterController` works with no XPC services.
- First run: Sparkle asks the user's consent to check automatically (privacy-friendly).
- Only builds **≥ 1.1** can auto-update (they're the first with Sparkle). Anyone on
  v1.0-beta installs v1.1 once by hand, then auto-updates forever after.
- `release.sh` finds `generate_appcast` under DerivedData automatically; override with
  `SPARKLE_BIN=/path/to/generate_appcast` if needed.
