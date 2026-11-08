// Upstream's own device classes (client/public/js/ble/) against the polyfill,
// over a fake native side that implements bridge-protocol.md. An upstream
// change that needs more of Web Bluetooth than the bridge provides fails here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { settle } from "./harness.js";
import { UUID, click, fakeNative, kickr, obcRemote, strap } from "./fakeNative.js";
import { recorder } from "./recorder.js";
import { HeartRateMonitor, SmartTrainer } from "../../../client/public/js/ble/devices.js";
import { connectController } from "../../../client/public/js/ble/controllers.js";
import { OpenBikeControlController } from "../../../client/public/js/ble/openBikeControl.js";
import { ZwiftController } from "../../../client/public/js/ble/zwiftController.js";
import { grantedDevices, whenInRange } from "../../../client/public/js/ble/knownDevices.js";

/** One recorder and every native side across this file, checked by the last tests. */
const record = recorder();
const natives = [];

function bridge(...peripherals) {
  const { native, bluetooth } = fakeNative(peripherals, { wrap: record.wrap });
  natives.push(native);
  return { native, bluetooth, timers: manualTimers() };
}

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

function eventsOf(device) {
  const events = [];
  device.on("disconnected", () => events.push("disconnected"));
  device.on("reconnected", () => events.push("reconnected"));
  return events;
}

const writesTo = (native, characteristic) => native.writes.filter((write) => write.characteristic === characteristic).map((write) => write.bytes);
const options = ({ setTimeout, clearTimeout }) => ({ setTimeout, clearTimeout });

async function connectedTrainer() {
  const page = bridge(kickr());
  page.trainer = await SmartTrainer.connect(page.bluetooth, options(page.timers));
  page.readings = [];
  page.trainer.on("data", (reading) => page.readings.push(reading));
  await settle();
  return page;
}

// ---------------------------------------------------------------- trainer

test("SmartTrainer finds a KICKR through the chooser and subscribes to FTMS and Cycling Power", async () => {
  const { trainer } = await connectedTrainer();
  assert.deepEqual(trainer.sources, ["ftms", "cps"]);
});

test("SmartTrainer takes control: request control, then start, written with response", async () => {
  const { native } = await connectedTrainer();
  assert.deepEqual(
    native.writes.map(({ bytes, withResponse }) => ({ bytes, withResponse })),
    [{ bytes: [0x00], withResponse: true }, { bytes: [0x07], withResponse: true }],
  );
});

test("the trainer's acknowledgement gives SmartTrainer control of the resistance", async () => {
  const { trainer } = await connectedTrainer();
  assert.equal(trainer.canControlResistance, true);
});

test("indoor bike data reaches the ride as power and cadence", async () => {
  const page = await connectedTrainer();
  page.native.notify(kickr().id, UUID.FTMS, UUID.INDOOR_BIKE_DATA, [0x44, 0x00, 0x00, 0x00, 0xaa, 0x00, 0xd2, 0x00]);
  assert.deepEqual([page.readings.at(-1).power, page.readings.at(-1).cadence], [210, 85]);
});

test("a grade change arrives at the trainer as FTMS simulation parameters", async () => {
  const page = await connectedTrainer();
  await page.trainer.setGrade(4.5);
  assert.deepEqual(writesTo(page.native, UUID.CONTROL_POINT).at(-1), [0x11, 0x00, 0x00, 0xc2, 0x01, 0x28, 0x33]);
});

test("an ERG target arrives at the trainer as FTMS set target power", async () => {
  const page = await connectedTrainer();
  await page.trainer.setTargetPower(200);
  assert.deepEqual(writesTo(page.native, UUID.CONTROL_POINT).at(-1), [0x05, 0xc8, 0x00]);
});

test("a trainer that drops reconnects through the bridge, takes control and gets the last command again", async () => {
  const page = await connectedTrainer();
  const events = eventsOf(page.trainer);
  await page.trainer.setTargetPower(200);
  page.native.drop(kickr().id);
  await page.timers.runNext();
  assert.deepEqual([events, writesTo(page.native, UUID.CONTROL_POINT).slice(-3)], [["disconnected", "reconnected"], [[0x00], [0x07], [0x05, 0xc8, 0x00]]]);
});

test("after a reconnect, data flows once per packet (no doubled listeners)", async () => {
  const page = await connectedTrainer();
  page.native.drop(kickr().id);
  await page.timers.runNext();
  page.readings.length = 0;
  page.native.notify(kickr().id, UUID.CYCLING_POWER, UUID.POWER_MEASUREMENT, [0x00, 0x00, 0xfa, 0x00]);
  assert.equal(page.readings.length, 1);
});

// ------------------------------------------------------------- heart rate

test("a heart rate strap's measurements reach HeartRateMonitor", async () => {
  const page = bridge(strap());
  const monitor = await HeartRateMonitor.connect(page.bluetooth, options(page.timers));
  const beats = [];
  monitor.on("data", ({ heartRate }) => beats.push(heartRate));
  page.native.notify(strap().id, UUID.HEART_RATE, UUID.HR_MEASUREMENT, [0x00, 142]);
  assert.deepEqual(beats, [142]);
});

test("a strap that drops reconnects through the bridge", async () => {
  const page = bridge(strap());
  const monitor = await HeartRateMonitor.connect(page.bluetooth, options(page.timers));
  const events = eventsOf(monitor);
  page.native.drop(strap().id);
  await page.timers.runNext();
  assert.deepEqual(events, ["disconnected", "reconnected"]);
});

// ------------------------------------------------------------ Zwift Click

async function connectedClick() {
  const page = bridge(click());
  page.controller = await connectController(page.bluetooth, options(page.timers));
  return page;
}

test("connectController opens a Zwift Click as a ZwiftController", async () => {
  const { controller } = await connectedClick();
  assert.ok(controller instanceof ZwiftController);
});

test("the Click's RideOn handshake falls back to a write without response, as its characteristic needs", async () => {
  const { native } = await connectedClick();
  assert.deepEqual(native.writes, [{ id: click().id, characteristic: UUID.ZWIFT_SYNC_RX, bytes: [...Buffer.from("RideOn")], withResponse: false }]);
});

test("Click button notifications decode as button names", async () => {
  const page = await connectedClick();
  const states = [];
  page.controller.on("buttons", (buttons) => states.push(buttons));
  page.native.notify(click().id, UUID.ZWIFT, UUID.ZWIFT_ASYNC, [0x37, 0x08, 0x00, 0x10, 0x01]);
  page.native.notify(click().id, UUID.ZWIFT, UUID.ZWIFT_ASYNC, [0x37, 0x08, 0x01, 0x10, 0x01]);
  assert.deepEqual(states, [["shiftUp"], []]);
});

test("a Click that falls asleep reconnects once it is back", async () => {
  const page = await connectedClick();
  const events = eventsOf(page.controller);
  page.native.peripheral(click().id).asleep = true;
  page.native.drop(click().id);
  await page.timers.runNext();
  page.native.peripheral(click().id).asleep = false;
  await page.timers.runNext();
  assert.deepEqual(events, ["disconnected", "reconnected"]);
});

// -------------------------------------------------------- OpenBikeControl

async function connectedObc() {
  const page = bridge(obcRemote());
  page.controller = await connectController(page.bluetooth, options(page.timers));
  return page;
}

test("connectController opens an OpenBikeControl remote as one", async () => {
  const { controller } = await connectedObc();
  assert.ok(controller instanceof OpenBikeControlController);
});

test("the OpenBikeControl remote is told the app information with a write with response", async () => {
  const { native } = await connectedObc();
  assert.deepEqual(native.writes.map(({ characteristic, bytes, withResponse }) => [characteristic, bytes[0], withResponse]), [[UUID.OBC_APP_INFO, 0x04, true]]);
});

test("OpenBikeControl button notifications decode as button names", async () => {
  const page = await connectedObc();
  const states = [];
  page.controller.on("buttons", (buttons) => states.push(buttons));
  page.native.notify(obcRemote().id, UUID.OBC, UUID.OBC_BUTTONS, [0x01, 0x02, 0x01]);
  assert.deepEqual(states, [["shiftDown"]]);
});

// --------------------------------------------------------- known devices

test("grantedDevices finds a remembered trainer among the bridge's granted devices", async () => {
  const page = await connectedTrainer();
  const found = await grantedDevices([{ kind: "trainer", id: kickr().id, name: kickr().name }], page.bluetooth);
  assert.deepEqual(found.map(({ entry, device }) => [entry.kind, device.id]), [["trainer", kickr().id]]);
});

test("whenInRange resolves on the device's advertisement and stops watching", async () => {
  const page = bridge(click());
  const device = await page.bluetooth.requestDevice({ filters: [{ namePrefix: "Zwift" }] });
  const inRange = whenInRange(device, options(page.timers));
  await settle();
  page.native.advertise(click().id);
  await inRange;
  await settle();
  assert.deepEqual(page.native.calls.filter((call) => call.op === "unwatchAdvertisements"), [{ op: "unwatchAdvertisements", watchId: "w1" }]);
});

// -------------------------------- a GATT timeout during set-up (T3b cases)

const takeControlWrite = (message) => message.op === "writeValue" && message.characteristic === UUID.CONTROL_POINT;
const appInfoWrite = (message) => message.op === "writeValue" && message.characteristic === UUID.OBC_APP_INFO;

test("a timeout while a new trainer takes control fails the connect, and the link stays down", async () => {
  const page = bridge(kickr());
  page.native.hangWhen(takeControlWrite);
  const connecting = SmartTrainer.connect(page.bluetooth, options(page.timers)).catch((error) => error);
  await page.native.nextHang();
  page.native.timeOut(kickr().id);
  const result = await connecting;
  assert.deepEqual([result.name, (await page.bluetooth.getDevices())[0].gatt.connected], ["NetworkError", false]);
});

test("a timeout while a reconnecting trainer takes control is no reconnect: it keeps trying", async () => {
  const page = await connectedTrainer();
  const events = eventsOf(page.trainer);
  page.native.drop(kickr().id);
  page.native.hangWhen(takeControlWrite);
  const attempt = page.timers.runNext();
  await page.native.nextHang();
  page.native.timeOut(kickr().id);
  await attempt;
  assert.deepEqual([events, page.trainer.connected, page.timers.pending().length], [["disconnected"], false, 1]);
});

test("after a timeout during take-control, the next attempt reconnects the trainer", async () => {
  const page = await connectedTrainer();
  const events = eventsOf(page.trainer);
  page.native.drop(kickr().id);
  page.native.hangWhen(takeControlWrite);
  const attempt = page.timers.runNext();
  await page.native.nextHang();
  page.native.timeOut(kickr().id);
  await attempt;
  page.native.stopHanging();
  await page.timers.runNext();
  assert.deepEqual([events, page.trainer.connected], [["disconnected", "reconnected"], true]);
});

test("a timeout during take-control whose drop arrives after the rejection: the trainer opens, then reconnects on the drop", async () => {
  const page = bridge(kickr());
  page.native.hangWhen(takeControlWrite);
  const connecting = SmartTrainer.connect(page.bluetooth, options(page.timers));
  await page.native.nextHang();
  page.native.stopHanging();
  page.native.timeOut(kickr().id, { eventFirst: false });
  const trainer = await connecting;
  const events = eventsOf(trainer);
  await settle();
  assert.deepEqual([events, trainer.connected, page.timers.pending().length], [["disconnected"], false, 1]);
});

test("a timeout while a new OpenBikeControl remote gets its app information fails the connect, and the link stays down", async () => {
  const page = bridge(obcRemote());
  page.native.hangWhen(appInfoWrite);
  const connecting = connectController(page.bluetooth, options(page.timers)).catch((error) => error);
  await page.native.nextHang();
  page.native.timeOut(obcRemote().id);
  const result = await connecting;
  assert.deepEqual([result.name, (await page.bluetooth.getDevices())[0].gatt.connected], ["NetworkError", false]);
});

test("a timeout while a reconnecting OpenBikeControl remote gets its app information is no reconnect: it keeps trying", async () => {
  const page = await connectedObc();
  const events = eventsOf(page.controller);
  page.native.drop(obcRemote().id);
  page.native.hangWhen(appInfoWrite);
  const attempt = page.timers.runNext();
  await page.native.nextHang();
  page.native.timeOut(obcRemote().id);
  await attempt;
  assert.deepEqual([events, page.controller.connected, page.timers.pending().length], [["disconnected"], false, 1]);
});

// ------------------------------------------------------------- the contract

test("upstream touched only bridged Web Bluetooth members", () => {
  assert.ok(record.touched.size > 0, "the recorder saw upstream at work");
  assert.deepEqual(record.outsideBridged(), []);
});

test("the polyfill reported no unbridged member while upstream ran", () => {
  assert.deepEqual(natives.flatMap((native) => native.reported), []);
});

test("every message upstream caused has the shape of a valid protocol fixture", () => {
  assert.deepEqual(natives.flatMap((native) => native.malformed), []);
});
