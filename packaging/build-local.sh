#!/bin/bash
# Build SSHTunnelManager.app (and a DMG) locally WITHOUT a full Xcode install —
# only the Command Line Tools (`xcode-select --install`) are needed.
#
#   packaging/build-local.sh            # -> build/SSHTunnelManager.app + .dmg
#   VERSION=1.12.0 packaging/build-local.sh
#
# With Xcode installed, prefer the regular build (see README / release.yml).
# Differences from an Xcode build, all cosmetic:
#   - no compiled asset catalog (the icon is built with iconutil; the accent
#     color falls back to the system one)
#   - the binary is built for this Mac's architecture only
#   - #Preview blocks are stripped (their macro plugin ships only with Xcode)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/SSHTunnelManager/SSHTunnelManager"
OUT="$ROOT/build"
APP="$OUT/SSHTunnelManager.app"
VERSION="${VERSION:-1.11.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCH="$(uname -m)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prefer a macOS 26 SDK when present: newer SDKs turn @State into a macro whose
# plugin ships only with Xcode. Override with SDK=/path/to/MacOSX.sdk.
if [ -z "${SDK:-}" ]; then
    SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
fi
echo "==> Building $VERSION ($BUILD_NUMBER) for $ARCH with $(basename "$SDK")"

# Compile from a copy with the trailing #Preview blocks removed.
cp -R "$SRC" "$WORK/src"
grep -rl '^#Preview' "$WORK/src" | while read -r f; do
    sed -i '' '/^#Preview/,$d' "$f"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

find "$WORK/src" -name '*.swift' -print0 | xargs -0 swiftc \
    -swift-version 5 -O \
    -sdk "$SDK" \
    -target "$ARCH-apple-macos14.0" \
    -module-name SSHTunnelManager \
    -parse-as-library \
    -o "$APP/Contents/MacOS/SSHTunnelManager"

# App icon from the asset catalog's PNGs.
ICONSET="$WORK/AppIcon.iconset"
ICONS="$SRC/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
cp "$ICONS/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICONS/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONS/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICONS/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Localizations: flatten the String Catalog into per-language .strings files
# (what Xcode's xcstringstool would do). Plain string units only.
python3 - "$SRC/Localizable.xcstrings" "$APP/Contents/Resources" <<'PY'
import json, os, sys
catalog = json.load(open(sys.argv[1], encoding="utf-8"))
source = catalog.get("sourceLanguage", "en")
tables = {}
for key, entry in catalog.get("strings", {}).items():
    for lang, loc in entry.get("localizations", {}).items():
        unit = loc.get("stringUnit")
        if lang != source and unit and unit.get("value"):
            tables.setdefault(lang, {})[key] = unit["value"]
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
for lang, table in tables.items():
    folder = os.path.join(sys.argv[2], f"{lang}.lproj")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as f:
        for key, value in sorted(table.items()):
            f.write(f'"{esc(key)}" = "{esc(value)}";\n')
    print(f"    {lang}: {len(table)} strings")
PY

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>SSHTunnelManager</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>io.github.0fuz.SSHTunnelManager</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>SSHTunnelManager</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature, same as the release workflow.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

# Plain drag-to-Applications DMG (the styled one needs dmgbuild; see release.yml).
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/SSHTunnelManager.dmg"
hdiutil create -quiet -volname "SSH Tunnel Manager" -srcfolder "$STAGE" -format UDZO "$OUT/SSHTunnelManager.dmg"

echo "==> $APP"
echo "==> $OUT/SSHTunnelManager.dmg"
