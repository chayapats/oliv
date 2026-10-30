#!/bin/bash
# Uses the Apple account signed into Xcode; never stores credentials.
set -euo pipefail

cd "$(dirname "$0")/.."
action="${1:-archive}"
case "$action" in
  archive|export|upload) ;;
  *) echo "Usage: $0 [archive|export|upload] [build-number]" >&2; exit 2 ;;
esac
build_number="${2:-$(sed -n "s/.*CURRENT_PROJECT_VERSION: '\([0-9]*\)'.*/\1/p" project.yml)}"
case "$build_number" in
  ''|*[!0-9]*) echo "Build number must be a positive integer." >&2; exit 2 ;;
esac
if [ "$build_number" -le 0 ]; then
  echo "Build number must be a positive integer." >&2
  exit 2
fi
# Operator-only settings kept out of git (the monorepo's gitignored
# release.local.env, shared with scripts/release.sh), e.g.
#   OLIV_DEFAULT_API_URL=https://oliv.example.com
# which the archive bakes into Info.plist as the Settings default server URL.
if [ -f ../release.local.env ]; then
  set -a; . ../release.local.env; set +a
fi
# A baked-in default reaches every new install, so it must be one the app
# accepts from anywhere (OlivConfiguration): https, a host, no credentials,
# query or fragment, and a port in 1...65535.
if [ -n "${OLIV_DEFAULT_API_URL:-}" ]; then
  if ! [[ "$OLIV_DEFAULT_API_URL" =~ ^https://[A-Za-z0-9.-]+(:([0-9]{1,5}))?(/[^[:space:]@?#]*)?$ ]] ||
     { [ -n "${BASH_REMATCH[2]}" ] && { [ "${BASH_REMATCH[2]}" -lt 1 ] || [ "${BASH_REMATCH[2]}" -gt 65535 ]; }; }; then
    echo "OLIV_DEFAULT_API_URL must be an https:// URL with a host, no query or fragment, and a port in 1-65535; got '$OLIV_DEFAULT_API_URL'" >&2
    exit 2
  fi
fi
output="$PWD/build/TestFlight"
archive="$output/Oliv-build-$build_number.xcarchive"
mkdir -p "$output"

if [ "$action" = archive ]; then
  if [ -e "$archive" ]; then
    echo "Archive already exists: $archive. Choose a new build number." >&2
    exit 1
  fi
  xcodebuild -project Oliv.xcodeproj -scheme Oliv -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -derivedDataPath "$output/DerivedData" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$build_number" OLIV_DEFAULT_API_URL="${OLIV_DEFAULT_API_URL:-}" archive
  baked="$(/usr/libexec/PlistBuddy -c 'Print :OLIVDefaultAPIURL' \
    "$archive/Products/Applications/Oliv.app/Info.plist" 2>/dev/null || true)"
  if [ "$baked" != "${OLIV_DEFAULT_API_URL:-}" ]; then
    echo "Archived Info.plist has OLIVDefaultAPIURL='$baked', expected '${OLIV_DEFAULT_API_URL:-}'." >&2
    exit 1
  fi
  echo "Default server URL baked into build $build_number: ${baked:-<none; users enter their own>}"
else
  if [ ! -d "$archive" ]; then
    echo "Run archive for build $build_number first." >&2
    exit 1
  fi
  options="$output/ExportOptions-$action-$build_number.plist"
  cp Scripts/TestFlightExportOptions.plist "$options"
  /usr/libexec/PlistBuddy -c "Set :destination $action" "$options"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportPath "$output/$action-$build_number" \
    -exportOptionsPlist "$options" -allowProvisioningUpdates
fi
