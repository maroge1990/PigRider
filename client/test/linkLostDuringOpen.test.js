// A link that drops while a device is being set up (e.g. during the trainer's
// take-control or a controller's app information, whose errors are swallowed)
// must fail the open: otherwise the device looks connected, and since its
// `gattserverdisconnected` listener comes only after the first open, it never
// reconnects either.
import { test } from "node:test";
import assert from "node:assert/strict";
import { HeartRateMonitor, SmartTrainer } from "../public/js/ble/devices.js";
import { ZwiftController } from "../public/js/ble/zwiftController.js";
import { openController } from "../public/js/ble/controllers.js";
import { ASYNC_CHARACTERISTIC, SYNC_RX_CHARACTERISTIC, SYNC_TX_CHARACTERISTIC, ZWIFT_SERVICE } from "../public/js/ble/zwiftProtocol.js";
import { APP_INFO_CHARACTERISTIC, BUTTON_STATE_CHARACTERISTIC, OBC_SERVICE } from "../public/js/ble/openBikeControlProtocol.js";
import { fakeTrainer } from "./fakeBluetooth.js";

const FTMS = 0x1826;
const BIKE_DATA = 0x2ad2;
const CONTROL = 0x2ad9;
const HEART_RATE = 0x180d;
const HR_MEASUREMENT = 0x2a37;

/** Timers that only run when the test says so. */
function manualTimers() {
  const timers = [];
  return {
    setTimeout: (fn, ms) => timers.push({ fn, ms }) - 1,
    clearTimeout: (id) => (timers[id] = null),
    pending: () => timers.filter(Boolean),
    async runNext() {
      const index = timers.findIndex(Boolean);
      const timer = timers[index];
      timers[index] = null;
      await timer.fn();
    },
  };
}

/** Records "disconnected" and "reconnected" from a device. */
function eventsOf(device) {
  const events = [];
  device.on("disconnected", () => events.push("disconnected"));
  device.on("reconnected", () => events.push("reconnected"));
  return events;
}

/** After a failed reconnect: no "reconnected", not connected, the next attempt planned. */
function assertStillReconnecting(device, events, timers) {
  assert.deepEqual(events, ["disconnected"], "no false reconnect");
  assert.equal(device.connected, false);
  assert.equal(timers.pending().length, 1, "another attempt follows");
}

/** The link drops while `characteristic` subscribes. */
function dropOnSubscribe(fake, characteristic) {
  const subscribe = characteristic.startNotifications;
  characteristic.startNotifications = async function () {
    fake.device.gatt.disconnect();
    return subscribe.call(this);
  };
}

/** The link drops on a write to `characteristic`. */
function dropOnWrite(fake, characteristic) {
  characteristic.onWrite = () => fake.device.gatt.disconnect();
}

const trainerFake = () => fakeTrainer({ name: "KICKR CORE", id: "kickr", services: { [FTMS]: { [BIKE_DATA]: {}, [CONTROL]: {} } } });
const strapFake = () => fakeTrainer({ name: "TICKR", id: "tickr", services: { [HEART_RATE]: { [HR_MEASUREMENT]: {} } } });
const clickFake = () => fakeTrainer({ name: "Zwift Click", id: "click", services: { [ZWIFT_SERVICE]: { [ASYNC_CHARACTERISTIC]: {}, [SYNC_RX_CHARACTERISTIC]: {}, [SYNC_TX_CHARACTERISTIC]: {} } } });
const obcFake = () => fakeTrainer({ name: "BikeControl", id: "obc", services: { [OBC_SERVICE]: { [BUTTON_STATE_CHARACTERISTIC]: {}, [APP_INFO_CHARACTERISTIC]: {} } } });

// ---------------------------------------------------------------- trainer ---

test("a trainer whose link drops while it takes control fails to open with a NetworkError", async () => {
  const fake = trainerFake();
  dropOnWrite(fake, fake.characteristics[CONTROL]);
  await assert.rejects(SmartTrainer.open(fake.device, manualTimers()), { name: "NetworkError" });
});

test("a trainer whose link drops while it takes control again after a drop keeps reconnecting instead of reporting it back", async () => {
  const fake = trainerFake();
  const timers = manualTimers();
  const trainer = await SmartTrainer.open(fake.device, timers);
  const events = eventsOf(trainer);
  dropOnWrite(fake, fake.characteristics[CONTROL]);
  fake.device.gatt.disconnect();
  await timers.runNext();
  assertStillReconnecting(trainer, events, timers);
});

// ------------------------------------------------------------- heart rate ---

test("a strap whose link drops while it subscribes fails to open with a NetworkError", async () => {
  const fake = strapFake();
  dropOnSubscribe(fake, fake.characteristics[HR_MEASUREMENT]);
  await assert.rejects(HeartRateMonitor.open(fake.device, manualTimers()), { name: "NetworkError" });
});

test("a strap whose link drops while it subscribes again after a drop keeps reconnecting instead of reporting it back", async () => {
  const fake = strapFake();
  const timers = manualTimers();
  const monitor = await HeartRateMonitor.open(fake.device, timers);
  const events = eventsOf(monitor);
  dropOnSubscribe(fake, fake.characteristics[HR_MEASUREMENT]);
  fake.device.gatt.disconnect();
  await timers.runNext();
  assertStillReconnecting(monitor, events, timers);
});

// ------------------------------------------------------------ Zwift Click ---

test("a Zwift controller whose link drops during the handshake fails to open with a NetworkError", async () => {
  const fake = clickFake();
  dropOnWrite(fake, fake.characteristics[SYNC_RX_CHARACTERISTIC]);
  await assert.rejects(ZwiftController.open(fake.device, manualTimers()), { name: "NetworkError" });
});

test("a Zwift controller whose link drops during the handshake after a drop keeps reconnecting instead of reporting it back", async () => {
  const fake = clickFake();
  const timers = manualTimers();
  const controller = await ZwiftController.open(fake.device, timers);
  const events = eventsOf(controller);
  dropOnWrite(fake, fake.characteristics[SYNC_RX_CHARACTERISTIC]);
  fake.device.gatt.disconnect();
  await timers.runNext();
  assertStillReconnecting(controller, events, timers);
});

// --------------------------------------------------------- OpenBikeControl ---

test("an OpenBikeControl controller whose link drops while it sends app information fails to open with a NetworkError", async () => {
  const fake = obcFake();
  dropOnWrite(fake, fake.characteristics[APP_INFO_CHARACTERISTIC]);
  await assert.rejects(openController(fake.device, manualTimers()), { name: "NetworkError" });
});

test("an OpenBikeControl controller whose link drops while it sends app information after a drop keeps reconnecting instead of reporting it back", async () => {
  const fake = obcFake();
  const timers = manualTimers();
  const controller = await openController(fake.device, timers);
  const events = eventsOf(controller);
  dropOnWrite(fake, fake.characteristics[APP_INFO_CHARACTERISTIC]);
  fake.device.gatt.disconnect();
  await timers.runNext();
  assertStillReconnecting(controller, events, timers);
});
