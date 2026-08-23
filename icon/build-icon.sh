#!/usr/bin/env bash
#
# Render icon/human-review.svg into the app icon assets.
#
# Produces:
#   bundle/AppIcon.icns   the icon install.sh copies into the .app bundle
#   docs/icon-512.png     a 512x512 still for the README
#
# Every iconset slice is rendered straight from the SVG at its target pixel
# size. Downscaling one large PNG instead would smear the 16px and 32px
# slices, and those are the ones Finder shows in list view.
#
# Re-runnable: it rebuilds every output from scratch on each run.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd -P)"
SVG="${REPO_ROOT}/icon/human-review.svg"
ICNS="${REPO_ROOT}/bundle/AppIcon.icns"
README_PNG="${REPO_ROOT}/docs/icon-512.png"

for tool in rsvg-convert iconutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "✗ Required tool not found: $tool"
    case "$tool" in
      rsvg-convert) echo "  Install it with:  brew install librsvg" ;;
      iconutil)     echo "  iconutil ships with macOS — are you on macOS?" ;;
    esac
    exit 1
  fi
done

if [[ ! -f "$SVG" ]]; then
  echo "✗ Missing $SVG"
  exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
mkdir -p "$ICONSET"

echo "→ Rendering iconset slices from $(basename "$SVG") ..."
render() {
  local px="$1" name="$2"
  rsvg-convert -w "$px" -h "$px" "$SVG" -o "${ICONSET}/${name}"
}

render   16 icon_16x16.png
render   32 icon_16x16@2x.png
render   32 icon_32x32.png
render   64 icon_32x32@2x.png
render  128 icon_128x128.png
render  256 icon_128x128@2x.png
render  256 icon_256x256.png
render  512 icon_256x256@2x.png
render  512 icon_512x512.png
render 1024 icon_512x512@2x.png

echo "→ Packing AppIcon.icns ..."
mkdir -p "${REPO_ROOT}/bundle" "${REPO_ROOT}/docs"
rm -f "$ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"

if [[ ! -s "$ICNS" ]]; then
  echo "✗ iconutil produced no output at $ICNS"
  exit 1
fi

echo "→ Rendering docs/icon-512.png ..."
rsvg-convert -w 512 -h 512 "$SVG" -o "$README_PNG"

echo "✓ $ICNS"
echo "✓ $README_PNG"
echo
echo "Info.plist already points at it via CFBundleIconFile = AppIcon."
echo "Run ./install.sh to rebuild the .app with this icon."
