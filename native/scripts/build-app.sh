#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-environment.sh
swift build --cache-path "$PWD/.build/cache" -c release -j 2
quiet_bin_dir="$(swift build --cache-path "$PWD/.build/cache" -c release --show-bin-path)"
quiet_app="$PWD/dist/Quiet.app"
mkdir -p "$quiet_app/Contents/MacOS" "$quiet_app/Contents/Resources"
cp "$quiet_bin_dir/QuietApp" "$quiet_app/Contents/MacOS/QuietApp"
cp "$quiet_bin_dir/quiet" "$quiet_app/Contents/MacOS/quiet"
codesign --force --sign - "$quiet_app/Contents/MacOS/quiet"
# Remove retired generated character scenes from prior local bundles.
for old_art in Glyph-icon.png Glyph-watercolor.png Glyph-overview-wash.png Glyph-workloads-wash.png Glyph-acceleration-wash.png; do
    rm -f "$quiet_app/Contents/Resources/$old_art"
done
for art in Resources/Glyph-*.png; do cp "$art" "$quiet_app/Contents/Resources/"; done
# Ship SwiftPM data bundles and the Metal shader library with the app.
for bundle in "$quiet_bin_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$quiet_app/Contents/Resources/"
done
if [ -f "$quiet_bin_dir/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
    cp "$quiet_bin_dir/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$quiet_app/Contents/MacOS/mlx.metallib"
    codesign --force --sign - "$quiet_app/Contents/MacOS/mlx.metallib"
fi
cp Resources/Quiet.icns "$quiet_app/Contents/Resources/QuietGlyph.icns"
cat > "$quiet_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Quiet</string>
<key>CFBundleDisplayName</key><string>Quiet</string>
<key>QuietPublisher</key><string>Mëngøh Labs</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mëngøh Labs.</string>
<key>CFBundleIdentifier</key><string>ai.quandrylabs.quiet</string>
<key>CFBundleExecutable</key><string>QuietApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.12.0</string>
<key>CFBundleVersion</key><string>18</string>
<key>CFBundleIconFile</key><string>QuietGlyph.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
bash scripts/package-licenses.sh "$quiet_app/Contents/Resources"
codesign --force --sign - "$quiet_app"
codesign --verify --strict "$quiet_app"
printf '%s\n' "$quiet_app"
