#!/bin/bash
# Local development bundle; no installation, launch, downloads, or settings changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$ROOT/.build/cache" "$ROOT/.build/config" "$ROOT/.build/security" "$ROOT/dist"
# This dependency-free package also builds inside a restricted host sandbox,
# where nesting SwiftPM's sandbox-exec is prohibited.
BUILD_OPTIONS=(--disable-sandbox --cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/config" --security-path "$ROOT/.build/security" --configuration release -debug-info-format none)
xcrun swift build "${BUILD_OPTIONS[@]}" --product Promptpad
BIN_DIR="$(xcrun swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
STAGING="$(mktemp -d "$ROOT/dist/.build-app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Promptpad.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bridge"
cp "$BIN_DIR/Promptpad" "$APP/Contents/MacOS/Promptpad"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp bridge/*.py bridge/README.md "$APP/Contents/Resources/bridge/"
cp README.md "$APP/Contents/Resources/README.md"
cp Sources/PromptpadCore/CONTRACT.md "$APP/Contents/Resources/CONTRACT.md"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"
# Stable bundle ID, ad-hoc development identity; no hardened runtime or notarization.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
rm -rf "$ROOT/dist/Promptpad.app"
mv "$APP" "$ROOT/dist/Promptpad.app"
printf 'Built and locally signed: %s\n' "$ROOT/dist/Promptpad.app"
