#!/usr/bin/env bash
# Signed builds with Mark's team. Runs ON THE MAC; `scripts/mac.sh ipad|testflight`
# copies the tree over and runs it with `ssh -t`, so the keychain password can be typed.
#   signed.sh ipad         development build, installed and launched on the iPad
#   signed.sh testflight   archive and upload to App Store Connect (internal TestFlight)
# Env: PIGRIDER_BUILD (CFBundleVersion, digits), PIGRIDER_COMMIT (short SHA, maybe "-dirty"),
#      PIGRIDER_IPAD (device name or id). Builds go to ./build, inside the tree being built.
set -euo pipefail
cmd=${1:-}
build=${PIGRIDER_BUILD:-}
commit=${PIGRIDER_COMMIT:-}
[[ "$build" =~ ^[0-9]+$ ]] || { echo "PIGRIDER_BUILD must be the build number (digits)" >&2; exit 2; }
[[ "$commit" =~ ^[0-9a-f]{7,40}(-dirty)?$ ]] || { echo "PIGRIDER_COMMIT must be a commit SHA" >&2; exit 2; }
export PATH=/opt/homebrew/bin:$PATH
cd "$(dirname "$0")/.."

# Xcode's account sits in the login keychain, which an ssh session cannot open on its own.
echo "== Unlock the login keychain (Mac password)"
security unlock-keychain ~/Library/Keychains/login.keychain-db
xcodegen generate --quiet
common=(-project PigRider.xcodeproj -scheme PigRider -destination "generic/platform=iOS"
        -allowProvisioningUpdates "CURRENT_PROJECT_VERSION=$build" "PIGRIDER_COMMIT=$commit")

case $cmd in
  ipad)
    device=${PIGRIDER_IPAD:-iPad}
    echo "== Development build $build"
    xcodebuild build "${common[@]}" -configuration Debug -derivedDataPath build/DeviceData -quiet
    echo "== Install and launch on $device"
    xcrun devicectl device install app --device "$device" build/DeviceData/Build/Products/Debug-iphoneos/PigRider.app
    xcrun devicectl device process launch --device "$device" com.maroge1990.pigrider
    ;;
  testflight)
    [[ "$commit" != *-dirty ]] || { echo "TestFlight builds come from a commit, not a working tree" >&2; exit 2; }
    echo "== Archive build $build ($commit)"
    xcodebuild archive "${common[@]}" -configuration Release -archivePath build/PigRider.xcarchive -quiet
    echo "== Upload to App Store Connect"
    xcodebuild -exportArchive -archivePath build/PigRider.xcarchive -exportOptionsPlist ExportOptions.plist \
      -exportPath build/export -allowProvisioningUpdates
    echo "== Uploaded build $build. TestFlight shows it after processing (usually 10-30 min)."
    ;;
  *) echo "usage: signed.sh ipad|testflight" >&2; exit 2 ;;
esac
