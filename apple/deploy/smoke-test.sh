#!/usr/bin/env bash
# Runs a PigRider server image the way the Unraid template does (user 99:100,
# read-only root, no capabilities) and checks that it serves the API, the
# client page and its own healthcheck. Used by pigrider-image.yml.
#   apple/deploy/smoke-test.sh IMAGE      (SMOKE_PORT, default 18080)
set -euo pipefail
image=${1:?usage: smoke-test.sh IMAGE}
port=${SMOKE_PORT:-18080}
origin="http://127.0.0.1:$port"
name="pigrider-smoke-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$name" \
  --user 99:100 --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /app/data:rw,uid=99,gid=100,mode=0700 \
  -p "127.0.0.1:$port:8080" \
  -e OPENRADLR_SERVER_NAME=PigRider -e OPENRADLR_PUBLIC_URL="$origin" -e OPENRADLR_ALLOWED_ORIGINS="$origin" \
  "$image" >/dev/null

fail() { echo "smoke test failed: $1" >&2; docker logs --tail 40 "$name" >&2 || true; exit 1; }
info=""
for _ in $(seq 60); do
  info=$(curl -fsS "$origin/api/info" 2>/dev/null) && break
  sleep 0.5
done
[ -n "$info" ] || fail "no answer on /api/info"
grep -q '"PigRider"' <<<"$info" || fail "/api/info does not name the server: $info"
# Fetch first, then search: `curl | grep -q` fails at random under pipefail, as
# grep stops reading at the first match and curl dies writing the rest (error 23).
page=$(curl -fsS "$origin/") || fail "no answer at /"
grep -qi "<html" <<<"$page" || fail "no client page at /"
docker exec "$name" openradlr-server healthcheck >/dev/null || fail "the image's healthcheck failed"
echo "smoke test passed: $image"
