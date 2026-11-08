# The server on passyflix

The ride server is upstream's image (Rust server, web client and routes),
built by the fork and run on Unraid like PigTV and PigMusic: a dockerMan
container from GHCR. Home network only, plain HTTP (ADR 0001).

| | |
| --- | --- |
| Container | `PigRider`, template [`apple/deploy/unraid/my-PigRider.xml`](../deploy/unraid/my-PigRider.xml) |
| Image | `ghcr.io/maroge1990/pigrider:release` |
| Address | `http://192.168.1.235:8080` (entered in the iPad app; give passyflix a fixed IP in the router) |
| Data | `/mnt/user/appdata/pigrider/data` (Strava logins once P2 is on; owned by 99:100) |

## How an image gets there

1. **Build.** Every push to `main` runs *PigRider image*: it builds upstream's
   `Dockerfile`, runs the result as Unraid will (user 99:100, read-only, no
   capabilities; `apple/deploy/smoke-test.sh`) and pushes `:sha-<commit>`
   (no `:latest`; nothing would use it). Pull requests run the same build and smoke test without pushing.
2. **Release.** *Actions → PigRider release → Run workflow* with the commit and
   the app's bridge version (PigRider settings → Bluetooth bridge). It checks
   the commit is on `main` and passed CI, and the deploy rule: the commit's
   `apple/BRIDGE_VERSION` must not exceed the app's. Then it points `:release`
   at that commit's image; it never rebuilds. A release needs Mark's OK.
3. **Update.** Unraid → Docker → PigRider → *Force Update* (or the update
   notice). The page reloads on the iPad with the new client.

Rollback: release the earlier commit, then Force Update.

## First install

Once, on passyflix (with Mark's OK):

```bash
mkdir -p /mnt/user/appdata/pigrider/data && chown 99:100 /mnt/user/appdata/pigrider/data
cp my-PigRider.xml /boot/config/plugins/dockerMan/templates-user/my-PigRider.xml
```

Then Unraid → Docker → *Add Container* → template *PigRider* → *Apply*.
The GHCR package must be public (GitHub → Packages → pigrider → settings), as
PigTV's is, or Unraid needs a registry login.

## Later

- Strava (P2): fill in *Secret key* in the container settings (`openssl rand
  -hex 32`, in Unraid only, never in the repo) and the Strava client id and
  secret variables then added to the template.
