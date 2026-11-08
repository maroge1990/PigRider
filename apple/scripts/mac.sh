#!/usr/bin/env bash
# Builds, tests and ships the iPad app on the Mac over ssh.
#   scripts/mac.sh test        generate the project, run unit tests on the simulator
#   scripts/mac.sh build       build for the simulator only
#   scripts/mac.sh ipad        signed development build of the working tree, installed on the iPad
#   scripts/mac.sh testflight  signed archive of HEAD's apple/, uploaded to TestFlight
# ipad and testflight ask for the Mac password (Xcode's account is in the login keychain).
# Env: PIGRIDER_MAC (ssh host, default "mac"), PIGRIDER_SIM (simulator name),
#      PIGRIDER_IPAD (device name or id, default "iPad").
set -euo pipefail

cmd=${1:-test}
host=${PIGRIDER_MAC:-mac}
sim=${PIGRIDER_SIM:-iPad Pro 11-inch (M5)}
remote=build/PigRider/apple
here=$(cd "$(dirname "$0")/.." && pwd)
logdir=$HOME/.cache/pigrider
log=$logdir/xcodebuild-$cmd.log
mkdir -p "$logdir"

commit=$(git -C "$here" rev-parse --short=12 HEAD)
# Build numbers are Unix times: they only grow, whatever the branch. The commit goes in the bundle.
build=$(date +%s)

if [ "$cmd" = testflight ]; then
  if [ -n "$(git -C "$here" status --porcelain -- .)" ]; then
    echo "Uncommitted changes in apple/: TestFlight uploads HEAD only. Commit first." >&2
    exit 1
  fi
  # A snapshot of HEAD's apple/ in its own folder on the Mac: no other run can change what is uploaded.
  work=build/PigRider-release/$build-$commit
  ssh "$host" "mkdir -p $work"
  git -C "$here" archive --format=tar --prefix=apple/ HEAD:apple | ssh "$host" "tar -x -C $work"
  echo "TestFlight build $build from $commit"
  ssh -t "$host" "cd $work/apple && PIGRIDER_BUILD=$build PIGRIDER_COMMIT=$commit scripts/signed.sh testflight"
  ssh "$host" "rm -rf $work"
  exit 0
fi

ssh "$host" "mkdir -p $remote"
rsync -az --delete --exclude '*.xcodeproj' --exclude build/ "$here/" "$host:$remote/"

case $cmd in
  test) action=test ;;
  build) action=build ;;
  ipad)
    [ -z "$(git -C "$here" status --porcelain -- .)" ] || commit="$commit-dirty"
    echo "Development build $build from $commit"
    exec ssh -t "$host" "cd $remote && PIGRIDER_BUILD=$build PIGRIDER_COMMIT=$commit PIGRIDER_IPAD=$(printf '%q' "${PIGRIDER_IPAD:-iPad}") scripts/signed.sh ipad" ;;
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
