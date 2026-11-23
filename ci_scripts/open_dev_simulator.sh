#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find simctl >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
simctl=$(xcrun --find simctl)
developer_dir=${simctl%/usr/bin/simctl}
device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
requested = sys.argv[1]
phones = [phone for runtime, devices in json.load(sys.stdin)["devices"].items()
          if ".iOS-" in runtime for phone in devices if phone["name"].startswith("iPhone")]
if requested:
    phones = [phone for phone in phones if requested in (phone["udid"], phone["name"])]
if not phones:
    sys.exit("No matching iPhone simulator. Check xcrun simctl list devices available.")
print(next((phone for phone in phones if phone["state"] == "Booted"), phones[-1])["udid"])
' "${1:-}")
xcrun simctl bootstatus "$device" -b
for viewer in "Device Hub" "Simulator"; do
  if [[ -d "$developer_dir/Applications/$viewer.app" ]]; then
    open "$developer_dir/Applications/$viewer.app" && break
  fi
done

build_dir="$HOME/Library/Developer/Xcode/DerivedData/GalaxyDevSimulator"
echo "Building Galaxy dev $(git rev-parse --short HEAD) for simulator $device"
xcodebuild -quiet -project GalaxyBluetooth.xcodeproj -scheme GalaxyBluetooth \
  -configuration Debug -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$build_dir" build
app="$build_dir/Build/Products/Debug-iphonesimulator/GalaxyBluetooth.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
xcrun simctl install "$device" "$app"
xcrun simctl launch --terminate-running-process "$device" "$bundle"
