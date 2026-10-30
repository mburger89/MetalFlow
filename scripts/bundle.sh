#!/bin/bash
# Builds build/MetalFlow.app, ad-hoc signed. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v metalui >/dev/null 2>&1; then
    metalui bundle --product MetalFlow --bundle-id com.mburger.MetalFlow --output build
    codesign --verify --strict --verbose=2 build/MetalFlow.app
    exit 0
fi

# No `metalui` CLI: lay the bundle out by hand, as MetalUI/docs/packaging.md describes.
APP=build/MetalFlow.app
swift build -c release --product MetalFlow
BIN=$(swift build -c release --product MetalFlow --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MetalFlow" "$APP/Contents/MacOS/"
# MetalUI's Metal shaders are a SwiftPM resource bundle (target MetalUIRender); it must sit in Contents/Resources.
cp -R "$BIN/MetalUI_MetalUIRender.bundle" "$APP/Contents/Resources/"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Third-party notices (packaging.md): stb_image is in every MetalUI binary on macOS.
METALUI=../MetalUI
cp "$METALUI/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
cp "$METALUI/Sources/CStbImage/LICENSE" "$APP/Contents/Resources/CStbImage-LICENSE"

plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
