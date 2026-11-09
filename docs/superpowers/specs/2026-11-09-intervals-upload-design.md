# intervals.icu upload — design

Date: 2026-11-09 · Issue: – · Status: implemented

## Goal

A rider on a private, single-rider server (a home server) sends a finished
ride to intervals.icu with one tap on the finish screen, next to *Upload to
Strava*. Rides uploaded straight to intervals.icu keep the full FIT file
(power, cadence, heart rate) and stay readable through the intervals.icu API,
which rides synced in from Strava are not.

## Decisions

| Question | Decision |
| --- | --- |
| Whose account | One account per server: the operator's. `OPENRADLR_INTERVALS_API_KEY` (intervals.icu → Settings → Developer Settings → API key). Uploads go to the key's own athlete (athlete id `0` in the API path). No per-rider sign-in, no OAuth |
| Meant for | Private servers with one rider. Every rider who can open the page uploads to the operator's account, so the docs say not to set it on a server others ride on. A public server keeps Strava only |
| What gets uploaded | The same FIT file the Strava upload sends (`recorder.toFit`, virtual ride, splits). Riders measured by a real trainer only, as for Strava |
| Route | `POST /api/intervals/upload?name=…`, body the FIT (or TCX) file, same body limit as Strava's. Answers `{ "activity_id": "<id>" \| null }` |
| Who may call it | Only the server's own page. The request's `Origin` must equal the origin of `OPENRADLR_PUBLIC_URL` (scheme, host, port); a missing, `null` or other `Origin` is 403 `foreign_origin`. And the `Content-Type` must be `application/vnd.ant.fit` or `application/vnd.garmin.tcx+xml` (415 otherwise), so a cross-site form or `text/plain` post cannot get through, and a cross-site `fetch` needs a CORS preflight the server never grants. Both checks run before the body is read or intervals.icu is contacted |
| Needs | `OPENRADLR_PUBLIC_URL`: setting the key without it is a config error at startup |
| Off | Without the key: `/api/intervals/*` answers 404 `intervals_disabled`, and `/api/info` has `intervals: { enabled: false }` |
| Upstream call | `POST https://intervals.icu/api/v1/athlete/0/activities?name=…&description=…`, multipart field `file`, HTTP Basic auth user `API_KEY`, password the key. Description: `Ridden on OpenRadlr: <public URL>` when `OPENRADLR_PUBLIC_URL` is set, otherwise none |
| Activity id | Read best-effort from the reply (`id`, or `activities[0].id`, a string). The intervals.icu docs do not state the reply's shape, so a missing id is not an error: the client then says "Uploaded" without a link |
| Duplicates | intervals.icu skips a file it already has (it hashes the data), so a second tap is harmless. The button still disables after a success |
| Errors | intervals.icu 401/403 → `intervals_key_rejected` (502, "the server's intervals.icu key was refused"); 429 → `intervals_busy` (503); other failures or a timeout (60 s) → `upload_failed` (502). The key never appears in logs, replies or config errors |
| HTTP client | Its own `reqwest::Client` with an explicit `User-Agent: OpenRadlr/<version>` (intervals.icu sits behind Cloudflare, which turns away some default agents). The base URL is a field of the config struct (not an env var) so tests point it at a local fake |
| Client | A button *Upload to intervals.icu* on the finish screen, its own status line (both uploads can run at once), shown when `info.intervals.enabled` and the ride was measured by a trainer. Link: `https://intervals.icu/activities/<id>` |
| Ride kept | A successful upload counts as keeping the ride (`rideKept()`), as Strava's does |

## Scope

In:

- Server: config (`OPENRADLR_INTERVALS_API_KEY`), the upload route, the
  intervals.icu client, `intervals` in `/api/info`.
- Client: `net/intervals.js` (fetch injected), the finish-screen button and
  status line, en + de texts.
- `docs/protocol.md` (HTTP table, `/api/info`, additive within version 2),
  `.env.example`, the README and `docs/deploy.md` config tables, CHANGELOG.

Out:

- The recovered-ride screen (#73). Its Strava upload discards the snapshot, so
  offering both uploads there needs its own change.
- Per-rider intervals.icu accounts (OAuth or a key per rider) for public
  servers.
- Automatic upload on finish. Each upload stays a tap.

## Security

The key can add activities to the operator's intervals.icu account (and,
being a personal API key, read and change it). It lives only in the server's
environment. The route never echoes it, logs redact it, and config errors
print `(hidden)`, and the key's type redacts itself in `Debug`.

There is no rider sign-in: on a private server everyone who opens the page is
the operator (home-network threat model). Two things that model does not
cover are handled:

- **Other web pages** (CSRF): a page the operator visits elsewhere could post a
  ride file to the home server, which needs no cookie. The `Origin` and
  `Content-Type` checks above refuse it. Non-browser callers must send the
  server's `Origin` themselves; anyone who can do that can already reach the
  server and is inside the threat model.
- **A public server with the key set** by mistake: any rider could add
  activities to the operator's account. The docs and the `.env.example`
  comment say private servers only.

## Testing

- Server unit tests: config (key optional, needs the public URL, hidden in errors and `Debug`), reply parsing
  (both id shapes, none), error mapping (401, 403, 429, 500, timeout),
  description with and without a public URL.
- Server end-to-end test: the real router against a local fake intervals.icu
  (axum on 127.0.0.1): checks the path, Basic auth, multipart `file`, `name`;
  `/api/info` reports `enabled`; 404 when off; a non-ride body is 400. A
  foreign, `null` or missing `Origin`, and a `text/plain` TCX post from the
  right origin, are refused without the fake being contacted. A same-origin
  FIT upload succeeds.
- Client tests (plain node, fake fetch): `IntervalsClient.upload` sends the
  file and name and returns the id; error replies become errors with the
  server's message; the button's visibility rule as a pure function.
