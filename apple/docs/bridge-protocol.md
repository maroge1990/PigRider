# Bridge protocol (JS ↔ Swift), version 1

The contract between `apple/web/bluetooth-bridge.js` (the `navigator.bluetooth`
polyfill) and the Swift `BluetoothBridge`. Both sides' tests use the examples
in `apple/web/test/fixtures/protocol.json`, so they cannot drift apart.

## Calls (JS → Swift)

`window.webkit.messageHandlers.ble.postMessage({op, ...args})` through a
`WKScriptMessageHandlerWithReply`. The reply is `{ok: true, value}` or
`{ok: false, error: {name, message}}`; `name` is a `DOMException` name
(`NotFoundError`, `NetworkError`, `SecurityError`, `NotSupportedError`,
`InvalidStateError`, `TimeoutError`). UUIDs are lowercase 128-bit strings;
bytes are base64.

| op | args | value |
| --- | --- | --- |
| `requestDevice` | `filters`, `optionalServices` | `{id, name}` |
| `getDevices` | none | `[{id, name}]` |
| `forget` | `id` | `null` |
| `watchAdvertisements` | `id`, `watchId` | `null` once watching |
| `unwatchAdvertisements` | `watchId` | `null` |
| `connect` | `id` | `{epoch}` |
| `disconnect` | `id`, `epoch?` | `null` |
| `getPrimaryService` | `id`, `service` | `null` (present and allowed) |
| `getCharacteristic` | `id`, `service`, `characteristic` | `{properties: [..]}` |
| `startNotifications` | `id`, `service`, `characteristic` | `null` |
| `writeValue` | `id`, `service`, `characteristic`, `value`, `withResponse` | `null` |
| `reportUnsupported` | `method` | `null` (native shows a banner) |

Filters are as in Web Bluetooth after normalisation: `{services?, name?,
namePrefix?, manufacturerData?: [{companyIdentifier}]}`.

Limits enforced by Swift: `id` is a granted peripheral of the calling origin;
`service` is in that grant; `value` ≤ 512 bytes; at most 8 filters and 16
services per request; strings ≤ 248 bytes.

## Events (Swift → JS)

`callAsyncJavaScript("globalThis.__pigriderBle.dispatch(e)", arguments: ["e": event], in: .page)`,
in arrival order.

| type | fields |
| --- | --- |
| `value` | `id`, `epoch`, `service`, `characteristic`, `value` (base64) |
| `disconnected` | `id`, `epoch` |
| `advertisement` | `watchId`, `id`, `name`, `rssi` |

Which `value` and `disconnected` events apply is defined under "Connection
state and timing" below. `advertisement` events for a `watchId` the polyfill
no longer has are ignored.

## Connection state and timing

Replies and events travel on different channels, so their relative order is
not guaranteed. These rules make every interleaving safe.

- **Epochs are assigned when a connect starts.** Swift increments the device's
  epoch before calling `connect(_:)` and tags that attempt's reply and every
  later event with it. Epochs only grow.
- **Disconnect wins.** The polyfill keeps, per device, the highest epoch seen in
  a `disconnected` event. A `connect` reply whose epoch is ≤ that value rejects
  with `NetworkError` ("disconnected while connecting") and leaves
  `gatt.connected` false; upstream's `connectGatt` retries `NetworkError`.
- **One link per device, many attempts.** CoreBluetooth has one connection
  per peripheral. A `connect` while an attempt is pending or the device is
  connected bumps the epoch; when the link comes up, every pending attempt's
  reply carries its own epoch, and later events carry the newest.
- **Superseded attempts.** The polyfill counts connect attempts per device. If
  `disconnect()` or a newer `connect()` happened after an attempt was sent, that
  attempt's reply never sets `connected` and the promise rejects with
  `AbortError`. If the superseding call was `disconnect()`, a success is
  answered with `disconnect {id, epoch: <that reply's epoch>}`.
- **Epoch-scoped disconnect.** `disconnect` with an `epoch` cancels the link only
  if that epoch is still the device's newest; otherwise Swift ignores it. A
  `disconnect` without `epoch` (the page's own `gatt.disconnect()`) always
  cancels. So cleaning up a stale success can never cut a newer connection.
- **Which events apply.** `value` events apply only for the current connected
  epoch. A `disconnected` event for the current epoch ends the connection and
  fires `gattserverdisconnected` once; for an older epoch it only updates the
  highest-seen record; for a newer epoch (its connect reply is still on the
  way) it is recorded so that reply rejects.

## GATT operations and timeouts

CoreBluetooth callbacks carry no request id, so Swift never lets two
operations of the same kind overlap on one characteristic, and a lost
callback ends the connection instead of being guessed at.

- **Property checks first.** `writeValue` with `withResponse` on a
  characteristic without the `write` property (or without response and no
  `writeWithoutResponse`) rejects with `NotSupportedError` at once, without
  touching CoreBluetooth, as Chrome does. (Upstream's Zwift helper falls back
  from one write type to the other on such errors.)
- **Timeout = connection lost.** A GATT operation without a callback within
  10 s makes Swift cancel the connection: every pending and queued operation
  of that peripheral rejects with `NetworkError`, its queues and discovery
  cache are cleared, and a `disconnected` event with the current epoch is sent.
- **Fencing.** Callbacks are matched to a queue only while the peripheral is
  in the `connected(epoch)` state the queue belongs to; anything arriving for
  a cleared queue or in another state is dropped. CoreBluetooth delivers
  delegate callbacks in order on the main queue, so a callback of the old
  connection cannot arrive after the new connection's `didConnect`.
- **Write without response** waits for `canSendWriteWithoutResponse` (or
  `peripheralIsReady(toSendWriteWithoutResponse:)`) and resolves once handed
  to CoreBluetooth.
