#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
swift test
if [[ -z "${OLIV_SIMULATOR_ID:-}" ]]; then
  OLIV_SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devices=json.load(sys.stdin)["devices"]
phones=[d for values in devices.values() for d in values if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not phones: raise SystemExit("No available iPhone simulator. Install an iOS runtime in Xcode.")
booted=[d for d in phones if d["state"]=="Booted"]
print((booted or phones)[0]["udid"])
')"
fi
if ! xcrun simctl list devices booted -j | python3 -c '
import json,sys
target=sys.argv[1]
raise SystemExit(not any(d["udid"]==target for ds in json.load(sys.stdin)["devices"].values() for d in ds))
' "$OLIV_SIMULATOR_ID"; then
  xcrun simctl boot "$OLIV_SIMULATOR_ID"
fi
xcrun simctl bootstatus "$OLIV_SIMULATOR_ID" -b
args=()
if [[ "${OLIV_RUN_MICROPHONE_TESTS:-0}" != "1" ]]; then
  args+=("-skip-testing:OlivTests/AppModelTests/testRealAudioRecorderProducesCompatiblePCMWithoutNetworking")
  args+=("-skip-testing:OlivTests/AudioPipelineTests/testRealAutomaticCaptureEngineRecordsAnalyzesAndRestartsWithoutNetworking")
fi
xcodebuild -project Oliv.xcodeproj -scheme Oliv \
  -destination "platform=iOS Simulator,id=$OLIV_SIMULATOR_ID" \
  -derivedDataPath build/DerivedData \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 \
  "${args[@]}" test
