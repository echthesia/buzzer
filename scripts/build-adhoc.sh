#!/usr/bin/env bash
#
# Build a signed Ad Hoc .ipa of the Buzzer app and optionally install it on a
# connected device. Ad Hoc builds use the PRODUCTION APNs environment, so the
# device token they produce works against the deployed relay
# (https://buzzer.melissaefoster.com) — unlike an Xcode dev build's sandbox token.
#
# Usage:
#   scripts/build-adhoc.sh                 # build only -> build/adhoc/Buzzer.ipa
#   scripts/build-adhoc.sh <device-udid>   # build, then install on that device
#
# Find the device UDID with:  xcrun devicectl list devices
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
proj_dir="$repo_root/Buzzer"
build_dir="$repo_root/build"
archive="$build_dir/Buzzer.xcarchive"
export_dir="$build_dir/adhoc"

echo "==> Archiving (Release)…"
xcodebuild archive \
	-project "$proj_dir/Buzzer.xcodeproj" \
	-scheme Buzzer \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$archive" \
	-allowProvisioningUpdates

echo "==> Exporting Ad Hoc .ipa…"
xcodebuild -exportArchive \
	-archivePath "$archive" \
	-exportPath "$export_dir" \
	-exportOptionsPlist "$proj_dir/ExportOptions-adhoc.plist" \
	-allowProvisioningUpdates

ipa="$export_dir/Buzzer.ipa"
echo "==> Built: $ipa"

if [[ "${1:-}" != "" ]]; then
	echo "==> Installing on device $1…"
	xcrun devicectl device install app --device "$1" "$ipa"
	echo "==> Installed. Launch Buzzer, grant notifications, set the relay to"
	echo "    https://buzzer.melissaefoster.com + the BUZZER_TOKEN, then Register."
fi
