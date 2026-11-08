import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { BIKE_DATA, CONTROL, DEVICE, FIXTURES, FTMS, ORIGIN, SCRIPT, connected, disconnected, install, settle, value, withDevice } from "./harness.js";

const lastBytes = (page) => [...Buffer.from(page.channel.messages("writeValue").at(-1).value, "base64")];

// ----------------------------------------------------------------- install

test("the script defines installPigriderBluetooth and nothing else at top level", () => {
  const context = vm.createContext({});
  const before = Object.getOwnPropertyNames(context);
  vm.runInContext(SCRIPT, context);
  assert.deepEqual(Object.getOwnPropertyNames(context).filter((name) => !before.includes(name)), ["installPigriderBluetooth"]);
});

test("pigriderBridge tells the bridge version and the protocol's ops", () => {
  const { bluetooth } = install({ version: 7 });
  assert.deepEqual({ ...bluetooth.pigriderBridge, ops: [...bluetooth.pigriderBridge.ops].sort() }, { version: 7, ops: [...FIXTURES.ops].sort() });
});

test("a page from another origin gets no navigator.bluetooth", () => {
  const { target } = install({ pageOrigin: "https://www.strava.com" });
  assert.equal(target.navigator.bluetooth, undefined);
});

test("a page from another origin gets no event entry point", () => {
  const { target } = install({ pageOrigin: "https://www.strava.com" });
  assert.equal(target.__pigriderBle, undefined);
});

test("without a channel, calls go to the WebKit message handler", async () => {
  const messages = [];
  const target = {
    location: { origin: ORIGIN },
    navigator: {},
    webkit: { messageHandlers: { ble: { postMessage: (message) => (messages.push(message), Promise.resolve({ ok: true, value: [] })) } } },
  };
  installPigriderBluetooth(target, { origin: ORIGIN, version: 1 });
  await target.navigator.bluetooth.getDevices();
  assert.deepEqual(messages, [{ op: "getDevices" }]);
});

// ------------------------------------------------------------------- UUIDs

async function requestedService(service) {
  const { bluetooth, channel } = install();
  channel.answer("requestDevice", DEVICE);
  await bluetooth.requestDevice({ filters: [{ services: [service] }] });
  return channel.messages("requestDevice")[0].filters[0].services[0];
}

test("a 16-bit UUID number becomes the lowercase 128-bit UUID", async () => {
  assert.equal(await requestedService(0x2ad9), CONTROL);
});

test("a short hex string becomes the lowercase 128-bit UUID", async () => {
  assert.deepEqual([await requestedService("2AD9"), await requestedService("0x2ad9")], [CONTROL, CONTROL]);
});

test("a full UUID is lowercased", async () => {
  assert.equal(await requestedService("00000001-19CA-4651-86E5-FA29DCDD09D1"), "00000001-19ca-4651-86e5-fa29dcdd09d1");
});

test("an invalid UUID rejects with a TypeError and calls nothing", async () => {
  const { bluetooth, channel } = install();
  await assert.rejects(bluetooth.requestDevice({ filters: [{ services: ["heart rate"] }] }), TypeError);
  assert.deepEqual(channel.calls, []);
});

// ---------------------------------------------------------- requestDevice

test("requestDevice resolves with a device carrying the chosen id and name", async () => {
  const { device } = await withDevice();
  assert.deepEqual([device.id, device.name], [DEVICE.id, DEVICE.name]);
});

test("requestDevice and getDevices hand out the same object for a device", async () => {
  const { bluetooth, channel, device } = await withDevice();
  channel.answer("getDevices", [DEVICE]);
  const [again] = await bluetooth.getDevices();
  assert.equal(again, device);
});

test("an error reply rejects with a DOMException of that name and message", async () => {
  const { bluetooth, channel } = install();
  channel.answer("requestDevice", (call) => call.fail("NotFoundError", "No device selected."));
  const error = await bluetooth.requestDevice({ filters: [{ namePrefix: "Zwift" }] }).catch((caught) => caught);
  assert.deepEqual([error instanceof DOMException, error.name, error.message], [true, "NotFoundError", "No device selected."]);
});

test("requestDevice without filters rejects with a TypeError", async () => {
  const { bluetooth } = install();
  await assert.rejects(bluetooth.requestDevice({ filters: [] }), TypeError);
});

test("acceptAllDevices is not bridged: NotSupportedError, reported to the native side", async () => {
  const { bluetooth, channel } = install();
  await assert.rejects(bluetooth.requestDevice({ acceptAllDevices: true }), { name: "NotSupportedError" });
  assert.deepEqual(channel.messages(), [{ op: "reportUnsupported", method: "Bluetooth.requestDevice.acceptAllDevices" }]);
});

test("a filter option outside the bridged set is NotSupportedError, reported to the native side", async () => {
  const { bluetooth, channel } = install();
  await assert.rejects(bluetooth.requestDevice({ filters: [{ serviceData: [{ service: 0x1826 }] }] }), { name: "NotSupportedError" });
  assert.deepEqual(channel.messages(), [{ op: "reportUnsupported", method: "Bluetooth.requestDevice.filters.serviceData" }]);
});

// --------------------------------------------------------------- the link

test("a connected device's gatt says so and connect resolves with it", async () => {
  const page = await withDevice();
  const connecting = page.device.gatt.connect();
  page.channel.pending("connect")[0].ok({ epoch: 4 });
  assert.deepEqual([await connecting, page.device.gatt.connected], [page.device.gatt, true]);
});

test("disconnect() ends the connection at once", async () => {
  const { device } = await connected(await withDevice());
  device.gatt.disconnect();
  assert.equal(device.gatt.connected, false);
});

test("disconnect() fires gattserverdisconnected, once also when the native event follows", async () => {
  const page = await connected(await withDevice(), 4);
  let fired = 0;
  page.device.addEventListener("gattserverdisconnected", () => (fired += 1));
  page.device.gatt.disconnect();
  page.dispatch(disconnected(4));
  assert.equal(fired, 1);
});

test("a disconnected event for the current epoch ends the connection and fires gattserverdisconnected", async () => {
  const page = await connected(await withDevice(), 4);
  let fired = 0;
  page.device.addEventListener("gattserverdisconnected", () => (fired += 1));
  page.dispatch(disconnected(4));
  page.dispatch(disconnected(4));
  assert.deepEqual([fired, page.device.gatt.connected], [1, false]);
});

test("a disconnected event for an older epoch leaves the connection alone", async () => {
  const page = await connected(await withDevice(), 4);
  page.dispatch(disconnected(3));
  assert.equal(page.device.gatt.connected, true);
});

test("a disconnected event with a newer epoch (a second connect in flight) ends the connection: there is one link", async () => {
  const page = await connected(await withDevice(), 4);
  page.device.gatt.connect().catch(() => {});
  page.dispatch(disconnected(5));
  assert.equal(page.device.gatt.connected, false);
});

test("a connect while connected moves the connection to the new epoch", async () => {
  const page = await connected(await connected(await withDevice(), 4), 5);
  const characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  page.dispatch(value(4, [1]));
  page.dispatch(value(5, [2]));
  assert.deepEqual([...new Uint8Array(characteristic.value.buffer)], [2]);
});

test("disconnect() while nothing is connected or connecting calls nothing", async () => {
  const { device, channel } = await withDevice();
  device.gatt.disconnect();
  assert.deepEqual(channel.messages("disconnect"), []);
});

// ------------------------------------------------------------------- GATT

test("GATT lookups while disconnected reject with NetworkError and call nothing", async () => {
  const { device, channel } = await withDevice();
  await assert.rejects(device.gatt.getPrimaryService(FTMS), { name: "NetworkError" });
  assert.deepEqual(channel.messages("getPrimaryService"), []);
});

test("a characteristic is the same object on every lookup within a connection, so listeners are not doubled", async () => {
  const page = await connected(await withDevice(), 4);
  const first = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  const second = await (await page.device.gatt.getPrimaryService(0x1826)).getCharacteristic(0x2ad2);
  assert.equal(second, first);
});

test("a connect while connected keeps the connection's objects", async () => {
  const page = await connected(await withDevice(), 4);
  const first = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  await connected(page, 5);
  const second = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  assert.equal(second, first);
});

// ------------------------------------- objects belong to one connection

/** Discovers FTMS and Indoor Bike Data at epoch 4, then drops and reconnects at epoch 5. */
async function reconnectedWithStaleObjects() {
  const page = await connected(await withDevice(), 4);
  page.staleService = await page.device.gatt.getPrimaryService(FTMS);
  page.staleCharacteristic = await page.staleService.getCharacteristic(BIKE_DATA);
  page.dispatch(disconnected(4));
  await connected(page, 5);
  return page;
}

test("after a reconnect, getPrimaryService returns a new service object", async () => {
  const page = await reconnectedWithStaleObjects();
  assert.notEqual(await page.device.gatt.getPrimaryService(FTMS), page.staleService);
});

test("after a reconnect, getCharacteristic returns a new characteristic object", async () => {
  const page = await reconnectedWithStaleObjects();
  const fresh = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  assert.notEqual(fresh, page.staleCharacteristic);
});

test("a characteristic of an ended connection gets no value events of the next one", async () => {
  const page = await reconnectedWithStaleObjects();
  const fresh = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  const heard = [];
  page.staleCharacteristic.addEventListener("characteristicvaluechanged", () => heard.push("stale"));
  fresh.addEventListener("characteristicvaluechanged", () => heard.push("fresh"));
  page.dispatch(value(5, [1]));
  assert.deepEqual(heard, ["fresh"]);
});

test("a characteristic of an ended connection keeps its last value", async () => {
  const page = await connected(await withDevice(), 4);
  const characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  page.dispatch(value(4, [7]));
  page.dispatch(disconnected(4));
  await connected(page, 5);
  page.dispatch(value(5, [8]));
  assert.deepEqual([...new Uint8Array(characteristic.value.buffer)], [7]);
});

// Chrome checks the server first (NetworkError while disconnected), then the
// attribute (InvalidStateError "GATT … no longer exists" once its connection ended).

test("a service of an ended connection, used on the next one: InvalidStateError, nothing sent", async () => {
  const page = await reconnectedWithStaleObjects();
  page.channel.calls.length = 0;
  await assert.rejects(page.staleService.getCharacteristic(BIKE_DATA), { name: "InvalidStateError" });
  assert.deepEqual(page.channel.messages(), []);
});

test("a characteristic of an ended connection, startNotifications on the next one: InvalidStateError, nothing sent", async () => {
  const page = await reconnectedWithStaleObjects();
  page.channel.calls.length = 0;
  await assert.rejects(page.staleCharacteristic.startNotifications(), { name: "InvalidStateError" });
  assert.deepEqual(page.channel.messages(), []);
});

test("a characteristic of an ended connection, written on the next one: InvalidStateError, nothing sent", async () => {
  const page = await reconnectedWithStaleObjects();
  page.channel.calls.length = 0;
  await assert.rejects(page.staleCharacteristic.writeValueWithoutResponse(Uint8Array.of(1)), { name: "InvalidStateError" });
  assert.deepEqual(page.channel.messages(), []);
});

test("a characteristic of an ended connection, used while disconnected: NetworkError, as for any GATT operation", async () => {
  const page = await connected(await withDevice(), 4);
  const characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  page.dispatch(disconnected(4));
  await assert.rejects(characteristic.startNotifications(), { name: "NetworkError" });
});

test("a lookup whose connection ends before the reply rejects with NetworkError, also once reconnected", async () => {
  const page = await connected(await withDevice(), 4);
  page.channel.answer("getPrimaryService", () => {});
  const lookup = page.device.gatt.getPrimaryService(FTMS);
  page.dispatch(disconnected(4));
  await connected(page, 5);
  page.channel.pending("getPrimaryService")[0].ok();
  await assert.rejects(lookup, { name: "NetworkError" });
});

test("a characteristic's properties come from the native reply", async () => {
  const page = await connected(await withDevice());
  const characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(CONTROL);
  assert.deepEqual([characteristic.properties.write, characteristic.properties.indicate, characteristic.properties.writeWithoutResponse], [true, true, false]);
});

test("startNotifications resolves with the characteristic", async () => {
  const page = await connected(await withDevice());
  const characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  assert.equal(await characteristic.startNotifications(), characteristic);
});

async function controlPoint() {
  const page = await connected(await withDevice());
  page.characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(CONTROL);
  return page;
}

test("a write accepts an ArrayBuffer", async () => {
  const page = await controlPoint();
  await page.characteristic.writeValueWithResponse(Uint8Array.of(0x11, 0x22).buffer);
  assert.deepEqual(lastBytes(page), [0x11, 0x22]);
});

test("a write accepts a typed array, only its own part of the buffer", async () => {
  const page = await controlPoint();
  await page.characteristic.writeValueWithResponse(Uint8Array.of(9, 0x11, 0x22, 9).subarray(1, 3));
  assert.deepEqual(lastBytes(page), [0x11, 0x22]);
});

test("a write accepts a DataView, only its own part of the buffer", async () => {
  const page = await controlPoint();
  await page.characteristic.writeValueWithResponse(new DataView(Uint8Array.of(9, 0x11, 0x22, 9).buffer, 1, 2));
  assert.deepEqual(lastBytes(page), [0x11, 0x22]);
});

test("a write of something that is not bytes rejects with a TypeError", async () => {
  const page = await controlPoint();
  await assert.rejects(page.characteristic.writeValueWithResponse([0x11]), TypeError);
});

test("writeValueWithoutResponse asks for a write without response", async () => {
  const page = await controlPoint();
  await page.characteristic.writeValueWithoutResponse(Uint8Array.of(1));
  assert.equal(page.channel.messages("writeValue").at(-1).withResponse, false);
});

// ------------------------------------------------------------------ values

async function subscribed() {
  const page = await connected(await withDevice(), 4);
  page.characteristic = await (await page.device.gatt.getPrimaryService(FTMS)).getCharacteristic(BIKE_DATA);
  page.events = [];
  page.characteristic.addEventListener("characteristicvaluechanged", (event) => page.events.push({ target: event.target, view: event.target.value }));
  return page;
}

test("a value event fires characteristicvaluechanged with the characteristic as its target", async () => {
  const page = await subscribed();
  page.dispatch(value(4, [0x44, 0x00]));
  assert.equal(page.events[0].target, page.characteristic);
});

test("a value event sets the characteristic's value to the bytes", async () => {
  const page = await subscribed();
  page.dispatch(value(4, [0x44, 0x00, 0xc8]));
  assert.deepEqual([...new Uint8Array(page.characteristic.value.buffer)], [0x44, 0x00, 0xc8]);
});

test("every value event gets a fresh DataView", async () => {
  const page = await subscribed();
  page.dispatch(value(4, [1]));
  page.dispatch(value(4, [2]));
  assert.deepEqual([page.events[0].view !== page.events[1].view, page.events[0].view.getUint8(0)], [true, 1]);
});

test("value events of another epoch are dropped", async () => {
  const page = await subscribed();
  page.dispatch(value(3, [1]));
  page.dispatch(value(5, [1]));
  assert.equal(page.events.length, 0);
});

test("value events while disconnected are dropped", async () => {
  const page = await subscribed();
  page.device.gatt.disconnect();
  page.dispatch(value(4, [1]));
  assert.equal(page.events.length, 0);
});

test("value events for a characteristic the page never asked for are ignored", async () => {
  const page = await subscribed();
  assert.doesNotThrow(() => page.dispatch(value(4, [1], CONTROL)));
});

// --------------------------------------------------------- advertisements

async function watching(signal) {
  const page = await withDevice();
  page.channel.answer("watchAdvertisements");
  page.channel.answer("unwatchAdvertisements");
  page.sightings = [];
  page.device.addEventListener("advertisementreceived", (event) => page.sightings.push({ device: event.device, name: event.name, rssi: event.rssi }));
  await page.device.watchAdvertisements({ signal });
  return page;
}

const advertisement = (watchId = "w1") => ({ type: "advertisement", watchId, id: DEVICE.id, name: "Zwift Click", rssi: -61 });

test("an advertisement fires advertisementreceived with the device, name and signal strength", async () => {
  const page = await watching(new AbortController().signal);
  page.dispatch(advertisement());
  assert.deepEqual(page.sightings, [{ device: page.device, name: "Zwift Click", rssi: -61 }]);
});

test("aborting the signal stops the watch on the native side", async () => {
  const watch = new AbortController();
  const page = await watching(watch.signal);
  watch.abort();
  assert.deepEqual(page.channel.messages("unwatchAdvertisements"), [{ op: "unwatchAdvertisements", watchId: "w1" }]);
});

test("advertisements of an aborted watch are ignored", async () => {
  const watch = new AbortController();
  const page = await watching(watch.signal);
  watch.abort();
  page.dispatch(advertisement());
  assert.deepEqual(page.sightings, []);
});

test("an already aborted signal rejects with AbortError and calls nothing", async () => {
  const { device, channel } = await withDevice();
  await assert.rejects(device.watchAdvertisements({ signal: AbortSignal.abort() }), { name: "AbortError" });
  assert.deepEqual(channel.messages("watchAdvertisements"), []);
});

test("aborting before the watch is confirmed rejects with AbortError", async () => {
  const { device, channel } = await withDevice();
  channel.answer("unwatchAdvertisements");
  const watch = new AbortController();
  const watchingNow = device.watchAdvertisements({ signal: watch.signal });
  watch.abort();
  channel.pending("watchAdvertisements")[0].ok();
  await assert.rejects(watchingNow, { name: "AbortError" });
});

// ------------------------------------------------------- unbridged members

/** One object of each bridged type, on a connected device. */
async function bridgedObjects() {
  const page = await connected(await withDevice());
  const service = await page.device.gatt.getPrimaryService(FTMS);
  const characteristic = await service.getCharacteristic(BIKE_DATA);
  await settle();
  page.channel.calls.length = 0;
  return {
    page,
    objects: {
      Bluetooth: page.bluetooth,
      BluetoothDevice: page.device,
      BluetoothRemoteGATTServer: page.device.gatt,
      BluetoothRemoteGATTService: service,
      BluetoothRemoteGATTCharacteristic: characteristic,
    },
  };
}

test("an unbridged member reads as undefined, as in a browser without it", async () => {
  const { objects } = await bridgedObjects();
  assert.equal(objects.Bluetooth.getAvailability, undefined);
});

test("reading an unbridged member reports it to the native side once, by type and member", async () => {
  const { page, objects } = await bridgedObjects();
  for (const [type, object] of Object.entries(objects)) void object.notBridgedYet, void object.notBridgedYet, void type;
  assert.deepEqual(
    page.channel.messages("reportUnsupported").map((message) => message.method),
    Object.keys(objects).map((type) => `${type}.notBridgedYet`),
  );
});

test("assigning an unbridged member (an on… handler) reports it too", async () => {
  const { page, objects } = await bridgedObjects();
  objects.BluetoothDevice.ongattserverdisconnected = () => {};
  assert.deepEqual(page.channel.messages("reportUnsupported"), [{ op: "reportUnsupported", method: "BluetoothDevice.ongattserverdisconnected" }]);
});

test("promise, JSON and symbol probes are not reported", async () => {
  const { page, objects } = await bridgedObjects();
  for (const object of Object.values(objects)) {
    await Promise.resolve(object);
    void object.toJSON, void object[Symbol.toPrimitive], void object.constructor;
  }
  assert.deepEqual(page.channel.messages("reportUnsupported"), []);
});

test("the bridged objects are real EventTargets", async () => {
  const { objects } = await bridgedObjects();
  const fired = [];
  for (const [type, object] of Object.entries(objects)) {
    if (type === "BluetoothRemoteGATTServer") continue;
    object.addEventListener("ping", () => fired.push(type));
    object.dispatchEvent(new Event("ping"));
  }
  assert.deepEqual(fired, ["Bluetooth", "BluetoothDevice", "BluetoothRemoteGATTService", "BluetoothRemoteGATTCharacteristic"]);
});
