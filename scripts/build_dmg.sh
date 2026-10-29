#!/usr/bin/env bash
# Styled installer using hdiutil and a native Swift Finder metadata writer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: build_dmg.sh APP OUTPUT VOLUME_NAME}"
OUTPUT="${2:?missing output path}"
VOLUME="${3:?missing volume name}"
TOOL="$ROOT/build/native-tools/oliv-dmg"
[ -d "$APP" ] || { echo "App bundle does not exist" >&2; exit 1; }
if [ ! -x "$TOOL" ]; then
  swift build --package-path "$ROOT/tools/dmg" --configuration release
  mkdir -p "$ROOT/build/native-tools"
  cp "$ROOT/tools/dmg/.build/release/oliv-dmg" "$TOOL"
fi
OLIV_DMG_TEMP="$(mktemp -d)"
OLIV_DMG_MOUNT="$OLIV_DMG_TEMP/mounted"
OLIV_DMG_ATTACHED=0
cleanup() {
  if [ "$OLIV_DMG_ATTACHED" = 1 ]; then hdiutil detach "$OLIV_DMG_MOUNT" >/dev/null || true; fi
  rm -rf "$OLIV_DMG_TEMP"
}
trap cleanup EXIT
mkdir -p "$OLIV_DMG_TEMP/staging/.background" "$OLIV_DMG_MOUNT" "$(dirname "$OUTPUT")"
ditto "$APP" "$OLIV_DMG_TEMP/staging/OLIV.app"
ln -s /Applications "$OLIV_DMG_TEMP/staging/Applications"
cp "$ROOT/assets/dmg/bg.tiff" "$OLIV_DMG_TEMP/staging/.background/bg.tiff"
cp "$APP/Contents/Resources/AppIcon.icns" "$OLIV_DMG_TEMP/staging/.VolumeIcon.icns"
hdiutil create -srcfolder "$OLIV_DMG_TEMP/staging" -format UDRW -volname "$VOLUME" "$OLIV_DMG_TEMP/scratch.dmg" >/dev/null
hdiutil attach "$OLIV_DMG_TEMP/scratch.dmg" -nobrowse -noautoopen -mountpoint "$OLIV_DMG_MOUNT" >/dev/null
OLIV_DMG_ATTACHED=1
"$TOOL" layout "$OLIV_DMG_MOUNT"
xcrun SetFile -a C "$OLIV_DMG_MOUNT"
hdiutil detach "$OLIV_DMG_MOUNT" >/dev/null
OLIV_DMG_ATTACHED=0
hdiutil convert "$OLIV_DMG_TEMP/scratch.dmg" -format UDZO -o "$OLIV_DMG_TEMP/final.dmg" >/dev/null
hdiutil verify "$OLIV_DMG_TEMP/final.dmg" >/dev/null
mv "$OLIV_DMG_TEMP/final.dmg" "$OUTPUT"
printf 'Created %s\n' "$OUTPUT"
