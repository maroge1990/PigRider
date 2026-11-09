// A native side in JS that implements apple/docs/bridge-protocol.md over
// scripted peripherals, for running upstream's device classes against the
// polyfill. Replies resolve as promises; events go through
// __pigriderBle.dispatch, like callAsyncJavaScript.
import { FIXTURES, ORIGIN } from "./harness.js";

const uuid16 = (n) => `${n.toString(16).padStart(8, "0")}-0000-1000-8000-00805f9b34fb`;
export const UUID = {
  FTMS: uuid16(0x1826),
  INDOOR_BIKE_DATA: uuid16(0x2ad2),
  CONTROL_POINT: uuid16(0x2ad9),
  CYCLING_POWER: uuid16(0x1818),
  POWER_MEASUREMENT: uuid16(0x2a63),
  HEART_RATE: uuid16(0x180d),
  HR_MEASUREMENT: uuid16(0x2a37),
  ZWIFT: "00000001-19ca-4651-86e5-fa29dcdd09d1",
  ZWIFT_ASYNC: "00000002-19ca-4651-86e5-fa29dcdd09d1",
  ZWIFT_SYNC_RX: "00000003-19ca-4651-86e5-fa29dcdd09d1",
  ZWIFT_SYNC_TX: "00000004-19ca-4651-86e5-fa29dcdd09d1",
  OBC: "d273f680-d548-419d-b9d1-fa0472345229",
  OBC_BUTTONS: "d273f681-d548-419d-b9d1-fa0472345229",
  OBC_APP_INFO: "d273f683-d548-419d-b9d1-fa0472345229",
};

/** A KICKR-like trainer: FTMS (bike data, control point that acknowledges every write) and Cycling Power. */
export const kickr = () => ({
  id: "KICKR-0001",
  name: "KICKR CORE 1234",
  advertised: [UUID.FTMS, UUID.CYCLING_POWER],
  services: {
    [UUID.FTMS]: {
      [UUID.INDOOR_BIKE_DATA]: { properties: ["notify"] },
      [UUID.CONTROL_POINT]: { properties: ["write", "indicate"], respond: (bytes) => [0x80, bytes[0], 0x01] },
    },
    [UUID.CYCLING_POWER]: { [UUID.POWER_MEASUREMENT]: { properties: ["notify"] } },
  },
});

export const strap = () => ({
  id: "POLAR-0001",
  name: "Polar H10 7A1B2C3D",
  advertised: [UUID.HEART_RATE],
  services: { [UUID.HEART_RATE]: { [UUID.HR_MEASUREMENT]: { properties: ["notify"] } } },
});

/** A Zwift Click half: found by manufacturer data, its command characteristic takes writes without response only. */
export const click = () => ({
  id: "CLICK-0001",
  name: "Zwift Click",
  advertised: [],
  companyIdentifier: 0x094a,
  services: {
    [UUID.ZWIFT]: {
      [UUID.ZWIFT_ASYNC]: { properties: ["notify"] },
      [UUID.ZWIFT_SYNC_RX]: { properties: ["writeWithoutResponse"] },
      [UUID.ZWIFT_SYNC_TX]: { properties: ["indicate"] },
    },
  },
});

export const obcRemote = () => ({
  id: "OBC-0001",
  name: "BikeControl",
  advertised: [UUID.OBC],
  services: {
    [UUID.OBC]: {
      [UUID.OBC_BUTTONS]: { properties: ["notify"] },
      [UUID.OBC_APP_INFO]: { properties: ["write"] },
    },
  },
});

const callShapes = new Map();
for (const call of FIXTURES.calls.filter((entry) => entry.valid)) {
  const keys = Object.keys(call.message).sort().join(",");
  callShapes.set(call.message.op, new Set([...(callShapes.get(call.message.op) ?? []), keys]));
}

const fromBase64 = (text) => [...Buffer.from(text, "base64")];
const toBase64 = (bytes) => Buffer.from(bytes).toString("base64");
const error = (name, message = name) => ({ ok: false, error: { name, message } });

function matches(peripheral, filter) {
  if (filter.services && !filter.services.every((service) => peripheral.advertised.includes(service))) return false;
  if (filter.name !== undefined && peripheral.name !== filter.name) return false;
  if (filter.namePrefix !== undefined && !peripheral.name.startsWith(filter.namePrefix)) return false;
  if (filter.manufacturerData && !filter.manufacturerData.every((entry) => entry.companyIdentifier === peripheral.companyIdentifier)) return false;
  return true;
}

/**
 * @param {object[]} peripherals scripted peripherals (see kickr(), strap(), click(), obcRemote())
 * @param {{wrap?: (bluetooth: object) => object}} [options] e.g. a recorder around the page's bluetooth
 */
export function fakeNative(peripherals, { wrap = (bluetooth) => bluetooth } = {}) {
  const target = { location: { origin: ORIGIN }, navigator: {} };
  const byId = new Map(peripherals.map((peripheral) => [peripheral.id, { ...peripheral, epoch: 0, link: false, notifying: new Set(), hung: [] }]));
  const grants = new Map();
  const watches = new Map();
  const hangRules = [];
  const hangWaiters = [];

  const native = {
    /** Every call, for shape checks. */
    calls: [],
    /** Calls whose keys match no valid fixture of their op. */
    malformed: [],
    /** Members the polyfill reported as unbridged. */
    reported: [],
    /** Every write: {id, characteristic, bytes, withResponse}. */
    writes: [],
    peripheral: (id) => byId.get(id),
    dispatch: (event) => target.__pigriderBle.dispatch(event),

    /** The peripheral sends a notification or indication. */
    notify(id, service, characteristic, bytes) {
      const peripheral = byId.get(id);
      if (!peripheral.link || !peripheral.notifying.has(`${service} ${characteristic}`)) return;
      native.dispatch({ type: "value", id, epoch: peripheral.epoch, service, characteristic, value: toBase64(bytes) });
    },

    /** The peripheral advertises: every watch of it hears about it. */
    advertise(id, rssi = -60) {
      for (const [watchId, watchedId] of watches) {
        if (watchedId === id) native.dispatch({ type: "advertisement", watchId, id, name: byId.get(id).name, rssi });
      }
    },

    /** The link drops (out of range, power cycled). */
    drop(id) {
      const peripheral = byId.get(id);
      if (!peripheral.link) return;
      peripheral.link = false;
      peripheral.notifying.clear();
      native.dispatch({ type: "disconnected", id, epoch: peripheral.epoch });
    },

    /** Calls matching `rule(message)` get no reply until timeOut() (a lost CoreBluetooth callback). */
    hangWhen(rule) {
      hangRules.push(rule);
    },

    stopHanging() {
      hangRules.length = 0;
    },

    /** Resolves once a call hangs. */
    nextHang: () => new Promise((resolve) => hangWaiters.push(resolve)),

    /**
     * The 10 s GATT timeout: the connection is cancelled, a `disconnected`
     * event goes out first (eventFirst), then every hung call rejects with
     * NetworkError; or the other way round.
     */
    timeOut(id, { eventFirst = true } = {}) {
      const peripheral = byId.get(id);
      const rejectHung = () => peripheral.hung.splice(0).forEach((resolve) => resolve(error("NetworkError", "GATT operation timed out.")));
      if (eventFirst) {
        native.drop(id);
        rejectHung();
      } else {
        const epoch = peripheral.epoch;
        peripheral.link = false;
        peripheral.notifying.clear();
        rejectHung();
        setImmediate(() => native.dispatch({ type: "disconnected", id, epoch }));
      }
    },
  };

  function checkShape(message) {
    const keys = Object.keys(message).sort().join(",");
    if (!callShapes.get(message.op)?.has(keys)) native.malformed.push(message);
  }

  const handlers = {
    requestDevice({ filters, optionalServices }) {
      const chosen = [...byId.values()].find((peripheral) => filters.some((filter) => matches(peripheral, filter)));
      if (!chosen) return error("NotFoundError", "No device selected.");
      grants.set(chosen.id, new Set([...filters.flatMap((filter) => filter.services ?? []), ...optionalServices]));
      return { ok: true, value: { id: chosen.id, name: chosen.name } };
    },
    getDevices() {
      return { ok: true, value: [...grants.keys()].map((id) => ({ id, name: byId.get(id).name })) };
    },
    forget({ id }) {
      native.drop(id);
      grants.delete(id);
      return { ok: true, value: null };
    },
    watchAdvertisements({ id, watchId }) {
      watches.set(watchId, id);
      return { ok: true, value: null };
    },
    unwatchAdvertisements({ watchId }) {
      watches.delete(watchId);
      return { ok: true, value: null };
    },
    connect({ id }) {
      const peripheral = byId.get(id);
      peripheral.epoch += 1;
      if (peripheral.asleep) return error("NetworkError", "Connection failed.");
      peripheral.link = true;
      return { ok: true, value: { epoch: peripheral.epoch } };
    },
    disconnect({ id, epoch }) {
      const peripheral = byId.get(id);
      if (epoch === undefined || epoch === peripheral.epoch) setImmediate(() => native.drop(id));
      return { ok: true, value: null };
    },
    getPrimaryService({ id, service }) {
      const peripheral = byId.get(id);
      if (!peripheral.link) return error("NetworkError", "Disconnected.");
      if (!grants.get(id)?.has(service)) return error("SecurityError", "Service not allowed for this device.");
      if (!peripheral.services[service]) return error("NotFoundError", "No such service.");
      return { ok: true, value: null };
    },
    getCharacteristic({ id, service, characteristic }) {
      const peripheral = byId.get(id);
      if (!peripheral.link) return error("NetworkError", "Disconnected.");
      const found = peripheral.services[service]?.[characteristic];
      if (!found) return error("NotFoundError", "No such characteristic.");
      return { ok: true, value: { properties: found.properties } };
    },
    startNotifications({ id, service, characteristic }) {
      const peripheral = byId.get(id);
      if (!peripheral.link) return error("NetworkError", "Disconnected.");
      const { properties } = peripheral.services[service][characteristic];
      if (!properties.includes("notify") && !properties.includes("indicate")) return error("NotSupportedError", "Characteristic cannot notify.");
      peripheral.notifying.add(`${service} ${characteristic}`);
      return { ok: true, value: null };
    },
    writeValue({ id, service, characteristic, value, withResponse }) {
      const peripheral = byId.get(id);
      if (!peripheral.link) return error("NetworkError", "Disconnected.");
      const found = peripheral.services[service][characteristic];
      if (!found.properties.includes(withResponse ? "write" : "writeWithoutResponse")) return error("NotSupportedError", "Write type not supported.");
      const bytes = fromBase64(value);
      native.writes.push({ id, characteristic, bytes, withResponse });
      const answer = found.respond?.(bytes);
      if (answer) setImmediate(() => native.notify(id, service, characteristic, answer));
      return { ok: true, value: null };
    },
    reportUnsupported({ method }) {
      native.reported.push(method);
      return { ok: true, value: null };
    },
  };

  function post(message) {
    native.calls.push(message);
    checkShape(message);
    const peripheral = byId.get(message.id);
    if (peripheral && hangRules.some((rule) => rule(message))) {
      return new Promise((resolve) => {
        peripheral.hung.push(resolve);
        hangWaiters.splice(0).forEach((wake) => wake(message));
      });
    }
    const handler = handlers[message.op];
    return Promise.resolve(handler ? handler(message) : error("NotSupportedError", `Unknown op ${message.op}.`));
  }

  installPigriderBluetooth(target, { origin: ORIGIN, version: FIXTURES.version, channel: post });
  return { native, target, bluetooth: wrap(target.navigator.bluetooth) };
}
