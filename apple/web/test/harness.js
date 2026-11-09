// Loads the polyfill (a classic script) into this realm, so DataView,
// EventTarget and DOMException are the ones upstream's modules see, and
// installs it on a fake page with a fake native channel.
import { readFileSync } from "node:fs";
import vm from "node:vm";

export const SCRIPT = readFileSync(new URL("../bluetooth-bridge.js", import.meta.url), "utf8");
vm.runInThisContext(SCRIPT, { filename: "bluetooth-bridge.js" });

export const ORIGIN = "https://pigrider.example";
export const FIXTURES = JSON.parse(readFileSync(new URL("./fixtures/protocol.json", import.meta.url), "utf8"));

/** Lets pending replies and their continuations run (no timers involved). */
export const settle = () => new Promise((resolve) => setImmediate(resolve));

/**
 * A native side the test answers by hand: every call waits until the test
 * calls `ok(value)` or `fail(name)` on it, unless `answer(op, ...)` set an
 * automatic reply for that op.
 */
export function fakeChannel() {
  const calls = [];
  const automatic = new Map();
  return {
    calls,
    post(message) {
      return new Promise((resolve) => {
        const call = {
          message,
          ok: (value = null) => resolve({ ok: true, value }),
          fail: (name, text = `${name} from native`) => resolve({ ok: false, error: { name, message: text } }),
        };
        calls.push(call);
        automatic.get(message.op)?.(call);
      });
    },
    /** Answers every later call of `op` with `value` (or `reply(call)`). */
    answer(op, value = null) {
      automatic.set(op, typeof value === "function" ? value : (call) => call.ok(value));
    },
    messages: (op) => calls.map((call) => call.message).filter((message) => !op || message.op === op),
    pending: (op) => calls.filter((call) => call.message.op === op),
  };
}

/** `navigator`: the page's own navigator members (e.g. `clipboard` in a secure context, `userActivation`). */
export function install({ origin = ORIGIN, pageOrigin = origin, version = 1, navigator = {} } = {}) {
  const target = { location: { origin: pageOrigin }, navigator: { ...navigator } };
  const channel = fakeChannel();
  installPigriderBluetooth(target, { origin, version, channel: channel.post });
  return { target, channel, bluetooth: target.navigator.bluetooth, dispatch: (event) => target.__pigriderBle.dispatch(event) };
}

export const DEVICE = { id: "5F1E0C2A-7B3D-4E59-9A61-2C8D4B7E9F10", name: "KICKR CORE 1234" };
export const FTMS = "00001826-0000-1000-8000-00805f9b34fb";
export const BIKE_DATA = "00002ad2-0000-1000-8000-00805f9b34fb";
export const CONTROL = "00002ad9-0000-1000-8000-00805f9b34fb";

/** A page with one granted device; GATT lookups answer at once, connect waits for the test. */
export async function withDevice(options) {
  const page = install(options);
  page.channel.answer("requestDevice", DEVICE);
  page.channel.answer("getPrimaryService");
  page.channel.answer("getCharacteristic", { properties: ["write", "indicate", "notify"] });
  page.channel.answer("startNotifications");
  page.channel.answer("writeValue");
  page.channel.answer("disconnect");
  page.channel.answer("reportUnsupported");
  const device = await page.bluetooth.requestDevice({ filters: [{ services: [0x1826] }] });
  return { ...page, device };
}

/** Starts a connect and answers it with `epoch`. */
export async function connected(page, epoch = 4) {
  const connecting = page.device.gatt.connect();
  page.channel.pending("connect").at(-1).ok({ epoch });
  await connecting;
  return page;
}

export const value = (epoch, bytes, characteristic = BIKE_DATA) => ({
  type: "value",
  id: DEVICE.id,
  epoch,
  service: FTMS,
  characteristic,
  value: Buffer.from(bytes).toString("base64"),
});
export const disconnected = (epoch) => ({ type: "disconnected", id: DEVICE.id, epoch });
