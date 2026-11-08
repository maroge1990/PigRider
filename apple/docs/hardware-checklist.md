# Hardware checklist (P1, T8)

Run on the iPad with a development build, mirrored to the Apple TV. Note the
result of each line (✅ / ❌ + what happened) in the PR. On any ❌, use
*Device diagnostics → Copy report* in the app and paste it into the PR.

## Pairing
- [ ] KICKR Core appears in the chooser; connects; power and cadence shown
- [ ] Polar strap appears; heart rate shown
- [ ] Zwift Click: both halves pair (press a button to wake each)
- [ ] After an app restart, all devices reconnect without the chooser

## Riding (30 min, mirrored to the Apple TV)
- [ ] Climbs feel harder, descents easier (sim mode)
- [ ] Virtual shifting: each Click press changes resistance a step
- [ ] ERG: a set target holds when cadence changes
- [ ] The left Click half's known lock-up after ~1 min (upstream docs/devices.md): note whether it happens
- [ ] The 3D view runs smoothly on the TV (note anything choppy)

## Dropouts
- [ ] Unplug the KICKR for 10 s mid-ride: it reconnects, and resistance follows the road again
- [ ] Walk the Polar out of range and back: heart rate returns
- [ ] Switch to another app for 30 s and back: devices reconnect, no stale numbers
- [ ] Pull down Control Center mid-ride: the ride carries on
- [ ] Reload the page (pull to refresh, if available) mid-ride: devices reconnect

## Open question from the build
- [ ] Cancel a connect that is still pending (turn the trainer off while
      "Connecting…", wait for the error, turn it on, connect again): the
      second connect must not hang. If CoreBluetooth never confirms the
      cancel, the bridge may wait forever (Swift builder's note, P1).
