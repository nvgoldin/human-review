#!/usr/bin/env bash
# Build human-review and install it as a proper macOS .app bundle.
#
# Why a bundle? macOS TCC (microphone, speech recognition, etc.) attributes
# permissions per-bundle-identifier and refuses to attribute anything to a
# raw SwiftPM executable launched from the terminal — Fn-Fn dictation, mic
# access, etc. all silently no-op without this. The bundle is the smallest
# wrapper that makes TCC happy.
#
# Layout produced:
#   ~/Applications/human-review.app/
#   └── Contents/
#       ├── Info.plist                                (copied from bundle/Info.plist)
#       ├── MacOS/
#       │   └── human-review                          (the executable)
#       └── Resources/
#           └── human-review_human-review.bundle/     (SwiftPM resources;
#                                                      AppResources helper in
#                                                      main.swift looks here
#                                                      first — SwiftPM's
#                                                      default Bundle.module
#                                                      path would put it at
#                                                      the .app root which
#                                                      codesign rejects.)
#
#   ~/bin/human-review → ~/Applications/human-review.app/Contents/MacOS/human-review
#
# Re-runs are idempotent and ~1s slower than the previous direct-symlink flow.
set -euo pipefail

cd "$(dirname "$0")"

REPO_ROOT="$(pwd -P)"
APP_NAME="human-review"
BUNDLE_ID="dev.nadav.human-review"
APP_DIR="${HOME}/Applications/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
APP_MACOS="${CONTENTS}/MacOS"
APP_RES="${CONTENTS}/Resources"

echo "→ Building (release)..."
swift build -c release

BIN_SRC="${REPO_ROOT}/.build/release/${APP_NAME}"
RES_BUNDLE_NAME="human-review_human-review.bundle"
RES_BUNDLE_SRC="${REPO_ROOT}/.build/release/${RES_BUNDLE_NAME}"
INFO_SRC="${REPO_ROOT}/bundle/Info.plist"

if [[ ! -x "$BIN_SRC" ]]; then
  echo "✗ Build did not produce $BIN_SRC"
  exit 1
fi
if [[ ! -f "$INFO_SRC" ]]; then
  echo "✗ Missing $INFO_SRC — re-pull the repo or restore bundle/Info.plist"
  exit 1
fi

echo "→ Assembling .app bundle at ${APP_DIR} ..."
mkdir -p "$APP_MACOS" "$APP_RES"

# Binary
cp -f "$BIN_SRC" "${APP_MACOS}/${APP_NAME}"
chmod +x "${APP_MACOS}/${APP_NAME}"

# SwiftPM resource bundle lives in Contents/Resources/ — conventional spot,
# and codesign requires everything to be under Contents/. Our AppResources
# helper in main.swift looks here first before falling back to Bundle.module.
if [[ -d "$RES_BUNDLE_SRC" ]]; then
  rm -rf "${APP_RES}/${RES_BUNDLE_NAME}"
  cp -R "$RES_BUNDLE_SRC" "${APP_RES}/"
  # Clean up any leftover from a prior install layout that placed the bundle
  # at .app/ root or inside Contents/MacOS/.
  rm -rf "${APP_DIR}/${RES_BUNDLE_NAME}"
  rm -rf "${APP_MACOS}/${RES_BUNDLE_NAME}"
fi

# Info.plist — refreshed every build so template changes propagate.
cp -f "$INFO_SRC" "${CONTENTS}/Info.plist"

# Ad-hoc sign with a stable identifier. Without --identifier, every rebuild
# changes the signature hash and TCC sometimes re-prompts for mic/dictation;
# with it, the grant sticks across rebuilds (TCC keys off identifier + bundle id).
echo "→ Code-signing (ad-hoc, stable identifier)..."
# No --deep: the resource .bundle/ contains only HTML/JS/CSS (no Mach-O), and
# `--deep` makes codesign try to sign it as a code bundle and fail. Signing
# just the outer .app + its executable is enough for TCC attribution.
codesign --sign - \
  --identifier "$BUNDLE_ID" \
  --force \
  "$APP_DIR" >/dev/null 2>&1 || {
    echo "✗ codesign failed — dictation/mic will be silently denied by TCC."
    echo "  Try:  codesign --sign - --identifier $BUNDLE_ID --force \"$APP_DIR\""
    exit 1
  }

# Quick sanity: verify the bundle reads back correctly.
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${CONTENTS}/Info.plist" >/dev/null 2>&1; then
  echo "✗ Info.plist is malformed after install"
  exit 1
fi

# Repoint the terminal entry point at the in-bundle binary. macOS resolves
# Bundle.main via the binary's real path → walks up to the .app → reads the
# Info.plist we just placed. So `human-review file.md` from a shell still
# works, AND the running process now has a proper bundle identity.
BIN_DIR="${BIN_DIR:-$HOME/bin}"
mkdir -p "$BIN_DIR"
LINK="${BIN_DIR}/${APP_NAME}"
rm -f "$LINK"
ln -s "${APP_MACOS}/${APP_NAME}" "$LINK"

# Clean up any prior raw-binary install artifacts from the pre-bundle layout.
rm -rf "${BIN_DIR}/${RES_BUNDLE_NAME}"

echo "✓ Bundle:  ${APP_DIR}"
echo "✓ Symlink: ${LINK} → ${APP_MACOS}/${APP_NAME}"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "⚠  $BIN_DIR is not on your PATH. Add to your shell rc:"
  echo "      export PATH=\"\$HOME/bin:\$PATH\""
fi

echo
echo "Dictation: focus a composer textarea and double-tap Fn (or your"
echo "configured shortcut in System Settings ▸ Keyboard ▸ Dictation)."
echo
echo "Usage:  human-review <file.md> [<more.md> ...]"
