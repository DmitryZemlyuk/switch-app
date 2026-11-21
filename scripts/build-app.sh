#!/usr/bin/env bash
# Builds Switch.app (Apple silicon) and zips it into dist/. Runs on macOS (GitHub Actions or locally).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
BUILD=${BUILD_NUMBER:-1}
APP=dist/Switch.app

rm -rf dist && mkdir -p dist

echo "==> Matter helper"
(cd helper && npm ci && npm test && npm run build)

echo "==> Swift app"
(cd app && swift build -c release --arch arm64)

echo "==> Bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cp app/.build/arm64-apple-macosx/release/Switch "$APP/Contents/MacOS/Switch"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" app/Info.plist > "$APP/Contents/Info.plist"
cp -R app/Resources/*.lproj "$APP/Contents/Resources/"
cp helper/dist/matter-helper.mjs "$APP/Contents/Resources/helper/"

echo "==> Node runtime"
# Ship the Node the helper was just tested with (official arm64 build from actions/setup-node).
NODE_BIN=$(command -v node)
NODE_VER=$("$NODE_BIN" -p 'process.versions.node + " " + process.arch')
echo "bundling node $NODE_VER from $NODE_BIN"
case "$NODE_VER" in *arm64) ;; *) echo "need an arm64 node" >&2; exit 1 ;; esac
cp "$NODE_BIN" "$APP/Contents/Resources/helper/node"
chmod +x "$APP/Contents/Resources/helper/node"
[ -f "$(dirname "$NODE_BIN")/../LICENSE" ] && cp "$(dirname "$NODE_BIN")/../LICENSE" "$APP/Contents/Resources/helper/NODE-LICENSE"

echo "==> Icon"
ICONSET=dist/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size app/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) app/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Sign (ad-hoc)"
codesign --force --sign - "$APP/Contents/Resources/helper/node"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Smoke test: the bundled helper must start and report that it is not paired"
SMOKE_DIR=$(mktemp -d)
SMOKE_OUT=$( (sleep 15) | SWITCH_STORAGE_DIR="$SMOKE_DIR" "$APP/Contents/Resources/helper/node" "$APP/Contents/Resources/helper/matter-helper.mjs" 2>"$SMOKE_DIR/err.log" || true)
echo "$SMOKE_OUT"
if ! echo "$SMOKE_OUT" | grep -q '"state":"unpaired"'; then
  cat "$SMOKE_DIR/err.log" >&2
  echo "helper smoke test failed" >&2
  exit 1
fi
rm -rf "$SMOKE_DIR"

echo "==> Zip"
ditto -c -k --keepParent "$APP" "dist/Switch-$VERSION-macos-arm64.zip"
ls -la dist
