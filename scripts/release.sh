#!/usr/bin/env bash
#
# release.sh — archive → export (Developer ID) → DMG → notarize → staple.
#
# Prereqs (one-time, see notes at bottom):
#   1. A "Developer ID Application" cert in your login keychain.
#   2. Stored notarytool credentials:
#        xcrun notarytool store-credentials AIDrop-Notary \
#          --apple-id "you@example.com" --team-id ASN2KAJ266 \
#          --password "app-specific-password"
#
# Usage:
#   scripts/release.sh                 # signed + notarized + stapled (shippable)
#   SKIP_NOTARIZE=1 scripts/release.sh # signed DMG only — for a GitHub pre-release.
#                                      # Gatekeeper then needs `xattr -cr` on the DMG.
#
# Output: build/Dragaway-<version>.dmg
# (NOTARY_PROFILE below is your stored notarytool keychain profile name — leave as-is.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="MacNotchAI.xcodeproj"
SCHEME="MacNotchAI"
APP_NAME="MacNotchAI"
NOTARY_PROFILE="${NOTARY_PROFILE:-AIDrop-Notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-ed25519}"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGE_DIR="$BUILD_DIR/dmg-stage"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Run an xcodebuild step, streaming full output to a log; on failure print the
# real error: lines instead of a truncated tail.
run_xcb() {
  local log="$1"; shift
  if ! xcodebuild "$@" > "$log" 2>&1; then
    echo "✗ xcodebuild failed — error lines:" >&2
    grep -E "error:" "$log" | grep -v "build database" | head -n 30 >&2 || true
    echo "  (full log: $log)" >&2
    exit 1
  fi
}

echo "▸ 1/5  Archiving (Release)…"
run_xcb "$BUILD_DIR/archive.log" \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  clean archive

echo "▸ 2/5  Exporting (Developer ID)…"
run_xcb "$BUILD_DIR/export.log" \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$REPO_ROOT/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

APP_PATH="$(/usr/bin/find "$EXPORT_DIR" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || { echo "✗ exported .app not found in $EXPORT_DIR" >&2; exit 1; }
echo "  exported: $APP_PATH"

SPARKLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "✗ exported app is missing SUPublicEDKey; Sparkle will generate an unsigned appcast." >&2
  echo "  Add SUPublicEDKey to the app's Info.plist before releasing." >&2
  exit 1
fi

# Version for the DMG name (falls back to 0.0.0 if unreadable).
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="$BUILD_DIR/Dragaway-$VERSION.dmg"

echo "▸ 3/5  Building DMG…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "Dragaway" \
  -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG" >/dev/null
echo "  created: $DMG"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "▸ 4/4  Skipping notarization (SKIP_NOTARIZE=1)."
  echo
  echo "✓ Done (NOT notarized): $DMG"
  echo "  Users must run:  xattr -cr <path-to-dmg>   before opening (Gatekeeper)."
  exit 0
fi

echo "▸ 4/5  Notarizing (this can take a few minutes)…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ 5/6  Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── Sparkle appcast (auto-update feed) ───────────────────────────────────────
# Signs the notarized DMG with the EdDSA private key (in your login Keychain, from
# `generate_keys` — see SPARKLE_SETUP.md) and (re)generates appcast.xml. The DMG is
# hosted as a GitHub Release asset, so the enclosure URL points there.
echo "▸ 6/6  Sparkle appcast…"
GEN_APPCAST="${SPARKLE_BIN:-}"
if [[ -z "$GEN_APPCAST" ]]; then
  GEN_APPCAST="$(/usr/bin/find ~/Library/Developer/Xcode/DerivedData \
      -type f -name generate_appcast -path '*/Sparkle/*' -print -quit 2>/dev/null || true)"
fi
DL_PREFIX="https://github.com/mwallbrecher/Dragaway/releases/download/v$VERSION/"
if [[ -n "$GEN_APPCAST" && -x "$GEN_APPCAST" ]]; then
  # generate_appcast reads every archive in BUILD_DIR, signs it, and writes appcast.xml.
  # Keychain access for the EdDSA key fails silently in some shells, so prefer a
  # key FILE when present (create once:  generate_keys -x ~/.dragaway_sparkle_key).
  KEY_FILE="$HOME/.dragaway_sparkle_key"
  if [[ -f "$KEY_FILE" ]]; then
    "$GEN_APPCAST" --ed-key-file "$KEY_FILE" \
      --download-url-prefix "$DL_PREFIX" -o "$REPO_ROOT/appcast.xml" "$BUILD_DIR"
  else
    "$GEN_APPCAST" --account "$SPARKLE_ACCOUNT" \
      --download-url-prefix "$DL_PREFIX" -o "$REPO_ROOT/appcast.xml" "$BUILD_DIR"
  fi
  if ! awk -v dmg="Dragaway-$VERSION.dmg" \
      '/<enclosure / && index($0, dmg) && /edSignature=/ { found = 1 } END { exit found ? 0 : 1 }' \
      "$REPO_ROOT/appcast.xml"; then
    echo "✗ appcast entry for Dragaway-$VERSION.dmg is unsigned; installed apps will reject this update." >&2
    echo "  Check that the exported app contains SUPublicEDKey and that the private key is in Keychain account '$SPARKLE_ACCOUNT'." >&2
    echo "  Or export the key once: <sparkle>/bin/generate_keys -x ~/.dragaway_sparkle_key" >&2
    exit 1
  fi
  echo "  wrote: $REPO_ROOT/appcast.xml"
else
  echo "  ⚠ generate_appcast not found — set SPARKLE_BIN or add the Sparkle package first."
  echo "    Manual: <sparkle>/bin/generate_appcast --download-url-prefix '$DL_PREFIX' -o appcast.xml '$BUILD_DIR'"
fi

echo
echo "✓ Done: $DMG"
echo "  Verify on a clean Mac: right-click → Open should show no Gatekeeper warning."
echo
echo "  Ship the update:"
echo "   1. Upload $DMG as an asset on the GitHub release tagged v$VERSION."
echo "   2. Commit & push the updated appcast.xml to main."
echo "   Installed apps then see the update within ~6h (or via Check for Updates…)."
