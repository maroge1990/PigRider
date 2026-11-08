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

# HEAD is resolved once: the label and the uploaded tree come from the same commit.
full=$(git -C "$here" rev-parse --verify HEAD^{commit})
commit=${full:0:12}
# Build numbers are Unix times: they only grow, whatever the branch. The commit goes in the bundle.
build=$(date +%s)

if [ "$cmd" = testflight ]; then
  if [ -n "$(git -C "$here" status --porcelain -- .)" ]; then
    echo "Uncommitted changes in apple/: TestFlight uploads HEAD only. Commit first." >&2
    exit 1
  fi
  # A snapshot of that commit's apple/ in a fresh folder on the Mac (mktemp: never shared with
  # another run), so nothing else can change what is uploaded.
  work=$(ssh "$host" "mkdir -p build/PigRider-release && mktemp -d build/PigRider-release/$build-$commit.XXXXXX")
  [[ "$work" =~ ^build/PigRider-release/[0-9]+-[0-9a-f]+\.[A-Za-z0-9]+$ ]] || { echo "Unexpected folder: $work" >&2; exit 1; }
  # From the repo root: run inside apple/, git archive limits itself to that folder and finds nothing.
  git -C "$here/.." archive --format=tar --prefix=apple/ "$full:apple" | ssh "$host" "tar -x -C $work"
  ssh "$host" "test -f $work/apple/project.yml && test -x $work/apple/scripts/signed.sh" \
    || { echo "The snapshot on the Mac is incomplete." >&2; exit 1; }
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
