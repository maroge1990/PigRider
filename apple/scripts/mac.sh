#!/usr/bin/env bash
# Builds and tests the iPad app on the Mac over ssh.
#   scripts/mac.sh test     generate the project, run unit tests on the simulator
#   scripts/mac.sh build    build for the simulator only
#   scripts/mac.sh ipad     signed development build, installed on the iPad (asks for the Mac password)
#   scripts/mac.sh testflight  signed archive uploaded to TestFlight (committed tree only; asks for the password)
# Env: PIGRIDER_MAC (ssh host, default "mac"), PIGRIDER_SIM (simulator name),
#      PIGRIDER_IPAD (device name or id, default "iPad").
# The build number is the commit count of HEAD, so it grows along main.
set -euo pipefail

cmd=${1:-test}
host=${PIGRIDER_MAC:-mac}
sim=${PIGRIDER_SIM:-iPad Pro 11-inch (M5)}
remote=build/PigRider/apple
here=$(cd "$(dirname "$0")/.." && pwd)
logdir=$HOME/.cache/pigrider
log=$logdir/xcodebuild-$cmd.log
mkdir -p "$logdir"

if [ "$cmd" = testflight ] && [ -n "$(git -C "$here" status --porcelain -- .)" ]; then
  echo "Commit apple/ first: a TestFlight build must match a commit." >&2
  exit 1
fi

ssh "$host" "mkdir -p $remote"
rsync -az --delete --exclude '*.xcodeproj' --exclude build/ "$here/" "$host:$remote/"

case $cmd in
  test) action=test ;;
  build) action=build ;;
  ipad|testflight)
    build=$(git -C "$here" rev-list --count HEAD)
    echo "build $build ($(git -C "$here" rev-parse --short HEAD))"
    exec ssh -t "$host" "cd $remote && PIGRIDER_BUILD=$build PIGRIDER_IPAD=$(printf '%q' "${PIGRIDER_IPAD:-iPad}") scripts/signed.sh $cmd" ;;
  *) echo "usage: $0 test|build|ipad|testflight" >&2; exit 2 ;;
esac

dest=$(printf '%q' "platform=iOS Simulator,name=$sim")
if ssh "$host" "export PATH=/opt/homebrew/bin:\$PATH; cd $remote && xcodegen generate --quiet && \
    xcodebuild $action -project PigRider.xcodeproj -scheme PigRider -destination $dest \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO" >"$log" 2>&1; then
  grep -E "Test run with|\*\* (TEST|BUILD) SUCCEEDED" "$log" | tail -2
else
  grep -E "error:|✘|failed|\*\* (TEST|BUILD) FAILED" "$log" | head -40
  echo "full log: $log" >&2
  exit 1
fi
