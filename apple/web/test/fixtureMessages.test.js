// The messages the polyfill sends are the valid call fixtures of
// protocol.json, the contract the Swift side is tested against.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEVICE, FIXTURES, install, settle, withDevice } from "./harness.js";

const ZWIFT_SERVICE = "00000001-19ca-4651-86e5-fa29dcdd09d1";
const ZWIFT_SYNC_RX = "00000003-19ca-4651-86e5-fa29dcdd09d1";

async function requesting(options) {
  const page = install();
  page.channel.answer("requestDevice", DEVICE);
  await page.bluetooth.requestDevice(options);
  return page;
}

async function connectedPage({ epoch = 4 } = {}) {
  const page = await withDevice();
  page.channel.answer("connect", { epoch });
  await page.device.gatt.connect();
  return page;
}

const characteristic = async (page, service, uuid) => (await page.device.gatt.getPrimaryService(service)).getCharacteristic(uuid);

/** For each valid call fixture: what the page does to make the polyfill send it. */
const SCENARIOS = {
  "request a trainer by service": () => requesting({ filters: [{ services: [0x1826] }, { services: [0x1818] }], optionalServices: [0x1826, 0x1818] }),
  "request a Zwift controller by manufacturer or name prefix": () =>
    requesting({ filters: [{ manufacturerData: [{ companyIdentifier: 0x094a }] }, { namePrefix: "Zwift" }], optionalServices: [ZWIFT_SERVICE] }),
  "request a remembered device by name": () => requesting({ filters: [{ name: "KICKR CORE 1234" }], optionalServices: [0x1826] }),
  "list granted devices": async () => {
    const page = install();
    page.channel.answer("getDevices", []);
    await page.bluetooth.getDevices();
    return page;
  },
  "forget a device": async () => {
    const page = await withDevice();
    page.channel.answer("forget");
    await page.device.forget();
    return page;
  },
  "watch advertisements": async () => {
    const page = await withDevice();
    page.channel.answer("watchAdvertisements");
    await page.device.watchAdvertisements();
    return page;
  },
  "stop watching": async () => {
    const page = await withDevice();
    page.channel.answer("watchAdvertisements");
    page.channel.answer("unwatchAdvertisements");
    const watch = new AbortController();
    await page.device.watchAdvertisements({ signal: watch.signal });
    watch.abort();
    return page;
  },
  connect: () => connectedPage(),
  "disconnect (page)": async () => {
    const page = await connectedPage();
    page.device.gatt.disconnect();
    return page;
  },
  "disconnect a stale attempt": async () => {
    const page = await withDevice();
    const attempt = page.device.gatt.connect().catch(() => {});
    page.device.gatt.disconnect();
    page.channel.pending("connect")[0].ok({ epoch: 3 });
    await attempt;
    return page;
  },
  "get a service": async () => {
    const page = await connectedPage();
    await page.device.gatt.getPrimaryService(0x1826);
    return page;
  },
  "get a characteristic": async () => {
    const page = await connectedPage();
    await characteristic(page, 0x1826, 0x2ad9);
    return page;
  },
  "start notifications": async () => {
    const page = await connectedPage();
    await (await characteristic(page, 0x1826, 0x2ad2)).startNotifications();
    return page;
  },
  "write request control with response": async () => {
    const page = await connectedPage();
    await (await characteristic(page, 0x1826, 0x2ad9)).writeValueWithResponse(Uint8Array.of(0x00));
    return page;
  },
  "write RideOn without response": async () => {
    const page = await connectedPage();
    await (await characteristic(page, ZWIFT_SERVICE, ZWIFT_SYNC_RX)).writeValueWithoutResponse(new TextEncoder().encode("RideOn"));
    return page;
  },
  "report an unsupported member": async () => {
    const page = await withDevice();
    void page.bluetooth.getAvailability;
    return page;
  },
};

const valid = FIXTURES.calls.filter((call) => call.valid);
/** The member's name is free text: only the shape must match. */
const SHAPE_ONLY = new Set(["report an unsupported member"]);
const shape = (message) => Object.fromEntries(Object.entries(message).map(([key, value]) => [key, typeof value]));

test("every valid call fixture has a scenario here", () => {
  assert.deepEqual(valid.map((call) => call.name).filter((name) => !SCENARIOS[name]), []);
});

for (const fixture of valid) {
  test(`the polyfill sends the "${fixture.name}" fixture message`, async () => {
    const page = await SCENARIOS[fixture.name]();
    await settle();
    const sent = page.channel.messages(fixture.message.op).at(-1);
    if (SHAPE_ONLY.has(fixture.name)) assert.deepEqual(shape(sent), shape(fixture.message));
    else assert.deepEqual(sent, fixture.message);
  });
}
