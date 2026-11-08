#!/usr/bin/env bash
# Builds and tests the iPad app on the Mac over ssh.
#   scripts/mac.sh test     generate the project, run unit tests on the simulator
#   scripts/mac.sh build    build for the simulator only
# Env: PIGRIDER_MAC (ssh host, default "mac"), PIGRIDER_SIM (simulator name).
set -euo pipefail

cmd=${1:-test}
host=${PIGRIDER_MAC:-mac}
sim=${PIGRIDER_SIM:-iPad Pro 11-inch (M5)}
remote=build/PigRider/apple
here=$(cd "$(dirname "$0")/.." && pwd)
logdir=$HOME/.cache/pigrider
log=$logdir/xcodebuild-$cmd.log
mkdir -p "$logdir"

ssh "$host" "mkdir -p $remote"
rsync -az --delete --exclude '*.xcodeproj' --exclude build/ "$here/" "$host:$remote/"

case $cmd in
  test) action=test ;;
  build) action=build ;;
  *) echo "usage: $0 test|build" >&2; exit 2 ;;
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
