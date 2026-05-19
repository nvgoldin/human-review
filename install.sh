#!/usr/bin/env bash
# Build release binary in this repo and symlink ~/bin/human-review to it.
# Rebuilds in-place are immediately reflected — no copy step.
set -euo pipefail

cd "$(dirname "$0")"

echo "→ Building (release)..."
swift build -c release

BIN_DIR="${BIN_DIR:-$HOME/bin}"
mkdir -p "$BIN_DIR"

REPO_ROOT="$(pwd -P)"
BIN_SRC="$REPO_ROOT/.build/release/human-review"
LINK="$BIN_DIR/human-review"

if [[ ! -x "$BIN_SRC" ]]; then
  echo "✗ Build did not produce $BIN_SRC"
  exit 1
fi

# Remove any prior install (file or symlink); also clean up old md-review artifacts.
rm -f "$LINK"
rm -f "$BIN_DIR/md-review"
rm -rf "$BIN_DIR/md-review_md-review.bundle"
rm -rf "$BIN_DIR/human-review_human-review.bundle"

ln -s "$BIN_SRC" "$LINK"
echo "✓ Symlinked: $LINK -> $BIN_SRC"

# Resource bundle lives next to the binary inside .build/release — Bundle.module
# locates it via the real (symlink-resolved) executable path, so no extra step needed.

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "⚠  $BIN_DIR is not on your PATH. Add to your shell rc:"
  echo "      export PATH=\"\$HOME/bin:\$PATH\""
fi

echo
echo "Usage:  human-review <file.md> [<more.md> ...]"
