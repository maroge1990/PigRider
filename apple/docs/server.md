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

## Uploads to Strava and intervals.icu

The finish screen offers *Upload to Strava* and *Upload to intervals.icu*
once these are set. Secrets go in the Unraid container settings only, never in
the repo. After changing them: *Apply*, which restarts the container.

1. **Strava (off for now).** Strava's API needs the developer account to be a
   paid Strava subscriber (since June 2026), so these fields stay empty until
   Mark subscribes ([roadmap](roadmap.md)). Then: create an API app at <https://www.strava.com/settings/api>
   with *Authorization Callback Domain* `192.168.1.235` (the host of *Public
   URL*). Copy its client ID and client secret into *Strava client ID* and
   *Strava client secret*, and set *Secret key* (`openssl rand -hex 32`) so the
   login survives updates. On the iPad: start menu → *Connect with Strava*,
   keep "upload activities" ticked, and sign in with email and password ("Sign
   in with Apple/Google" leaves the app for Safari).
2. **intervals.icu.** intervals.icu → *Settings* → *Developer Settings* →
   API key, into *intervals.icu API key*. Every ride uploaded from this server
   goes to that account, so it suits a server only Mark rides on. The upload
   is accepted only from the page at *Public URL*: keep that exact.

On an existing install, add the three fields by hand: Unraid → Docker →
PigRider → *Edit* → *Add another Path, Port, Variable…* → *Variable*, with the
keys `OPENRADLR_STRAVA_CLIENT_ID`, `OPENRADLR_STRAVA_CLIENT_SECRET` and
`OPENRADLR_INTERVALS_API_KEY` (mask the two secrets). **Never copy the repo's
`my-PigRider.xml` over the saved one**: the saved file holds the container's
values, and overwriting it would blank the secret key and log Strava out.
