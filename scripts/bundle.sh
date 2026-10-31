#!/bin/bash
# Builds build/MetalFlow.app, ad-hoc signed, with `metalui bundle`. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MetalFlow.app
swift run --package-path ../MetalUI metalui bundle --product MetalFlow --bundle-id com.mburger.MetalFlow --version 0.1.0 --output build

# Third-party notices (packaging.md): stb_image is in every MetalUI binary on macOS.
METALUI=../MetalUI
cp "$METALUI/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
cp "$METALUI/Sources/CStbImage/LICENSE" "$APP/Contents/Resources/CStbImage-LICENSE"

# Copying into the bundle invalidates the seal `metalui bundle` made; sign again.
codesign --force --sign - --deep "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
