#!/usr/bin/env bash
#
# Build a signed, notarized Mac Catalyst .app of Buzzer and (optionally) install it
# to /Applications. The Mac build is Catalyst (not native AppKit) so the notification
# service extension runs via the iOS delivery path — native macOS SIGKILLs the NSE for
# "sluggish startup" before it can render custom sender avatars (see the project notes).
#
# Developer-ID export flips aps-environment dev->production, so the device token works
# against the deployed relay (https://buzzer.melissaefoster.com).
#
# Usage:
#   scripts/build-macos.sh            # build + notarize -> build/macos-catalyst/Buzzer.app
#   scripts/build-macos.sh --install  # also copy the stapled .app into /Applications
#
# Prereqs: a notarytool keychain profile named "default" (created once via
#   xcrun notarytool store-credentials default --apple-id … --team-id 9363F8639X --password <app-specific>
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
proj_dir="$repo_root/Buzzer"
build_dir="$repo_root/build"
archive="$build_dir/Buzzer-catalyst.xcarchive"
export_dir="$build_dir/macos-catalyst"
app="$export_dir/Buzzer.app"
notarize_profile="default"

echo "==> Archiving (Release, Mac Catalyst)…"
xcodebuild archive \
	-project "$proj_dir/Buzzer.xcodeproj" \
	-scheme Buzzer \
	-configuration Release \
	-destination 'generic/platform=macOS,variant=Mac Catalyst' \
	-archivePath "$archive" \
	-allowProvisioningUpdates

echo "==> Exporting Developer ID .app…"
rm -rf "$export_dir"
xcodebuild -exportArchive \
	-archivePath "$archive" \
	-exportPath "$export_dir" \
	-exportOptionsPlist "$proj_dir/ExportOptions-macos.plist" \
	-allowProvisioningUpdates

echo "==> Notarizing (keychain profile: $notarize_profile)…"
# notarytool needs a .zip/.dmg/.pkg, not a bare .app.
ditto -c -k --keepParent "$app" "$export_dir/Buzzer.zip"
xcrun notarytool submit "$export_dir/Buzzer.zip" --keychain-profile "$notarize_profile" --wait

echo "==> Stapling…"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
# Re-zip the stapled app for hand distribution.
rm -f "$export_dir/Buzzer.zip"
ditto -c -k --keepParent "$app" "$export_dir/Buzzer-notarized.zip"

echo "==> Built + notarized: $app"
echo "    Distributable zip: $export_dir/Buzzer-notarized.zip"

if [[ "${1:-}" == "--install" ]]; then
	echo "==> Installing to /Applications…"
	rm -rf "/Applications/Buzzer.app"
	ditto "$app" "/Applications/Buzzer.app"
	echo "==> Installed. Launch Buzzer, grant notifications, set the relay to"
	echo "    https://buzzer.melissaefoster.com + the BUZZER_TOKEN, then Register."
fi
