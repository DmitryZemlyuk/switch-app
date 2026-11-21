#!/usr/bin/env bash
# Builds Switch.app (Apple silicon) and zips it into dist/. Runs on macOS (GitHub Actions or locally).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
BUILD=${BUILD_NUMBER:-1}
NODE_VERSION=22.12.0
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

echo "==> Node runtime $NODE_VERSION"
curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-arm64.tar.gz" -o dist/node.tar.gz
tar -xzf dist/node.tar.gz -C dist "node-v$NODE_VERSION-darwin-arm64/bin/node" "node-v$NODE_VERSION-darwin-arm64/LICENSE"
cp "dist/node-v$NODE_VERSION-darwin-arm64/bin/node" "$APP/Contents/Resources/helper/node"
cp "dist/node-v$NODE_VERSION-darwin-arm64/LICENSE" "$APP/Contents/Resources/helper/NODE-LICENSE"
chmod +x "$APP/Contents/Resources/helper/node"

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

echo "==> Zip"
ditto -c -k --keepParent "$APP" "dist/Switch-$VERSION-macos-arm64.zip"
ls -la dist
