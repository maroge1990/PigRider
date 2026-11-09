// The navigator.bluetooth polyfill: the part of Web Bluetooth that upstream's
// client/public/js/ble/ uses, on top of the native bridge described in
// apple/docs/bridge-protocol.md. Over plain HTTP, where WebKit has no
// navigator.clipboard, it also provides clipboard.writeText (op copyText).
//
// A classic script (the app injects it as a WKUserScript) that defines one
// function and nothing else. The app appends a line that runs it:
//   installPigriderBluetooth(globalThis, { origin: "https://…", version: N });
// Tests pass `channel` (a function message => Promise<reply>) instead of the
// WebKit message handler.

"use strict";

// eslint-disable-next-line no-unused-vars
function installPigriderBluetooth(target, { origin, version, channel } = {}) {
  if (!target || !target.location || origin === undefined || target.location.origin !== origin) return;

  const OPS = Object.freeze([
    "requestDevice",
    "getDevices",
    "forget",
    "watchAdvertisements",
    "unwatchAdvertisements",
    "connect",
    "disconnect",
    "getPrimaryService",
    "getCharacteristic",
    "startNotifications",
    "writeValue",
    "reportUnsupported",
    "copyText",
  ]);
  const BASE_UUID_TAIL = "-0000-1000-8000-00805f9b34fb";
  const FULL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const SHORT_UUID = /^(?:0x)?([0-9a-f]{4}|[0-9a-f]{8})$/;
  /** Members that engines, promises, JSON and test tools probe on any object: not a use of Web Bluetooth. */
  const PROBES = new Set(["then", "toJSON", "inspect", "constructor", "nodeType", "tagName", "$$typeof", "asymmetricMatch", "_isMockFunction"]);
  const FILTER_KEYS = new Set(["services", "name", "namePrefix", "manufacturerData"]);
  const REQUEST_KEYS = new Set(["filters", "optionalServices", "acceptAllDevices"]);
  const PROPERTY_NAMES = ["broadcast", "read", "writeWithoutResponse", "write", "notify", "indicate", "authenticatedSignedWrites", "reliableWrite", "writableAuxiliaries"];

  const post = channel || ((message) => target.webkit.messageHandlers.ble.postMessage(message));
  const fail = (name, message) => new DOMException(message, name);

  /** One call to the native side; an error reply becomes a DOMException with its name. */
  async function call(op, args) {
    const reply = await post({ op, ...args });
    if (reply && reply.ok === true) return reply.value;
    const error = (reply && reply.error) || {};
    throw fail(error.name || "UnknownError", error.message || `${op} failed.`);
  }

  // ------------------------------------------------------- unbridged members

  const reported = new Set();

  /** Tells the native side (which shows a banner) about an API the page wanted, once per member. */
  function reportUnsupported(method) {
    if (reported.has(method)) return;
    reported.add(method);
    call("reportUnsupported", { method }).catch(() => {});
  }

  /**
   * A prototype that sits under a bridged class's own prototype: a lookup only
   * reaches it when the member is not bridged. It then reads as undefined, as
   * in a browser without that member, and is reported. `this` stays the real
   * object, so EventTarget's methods work.
   */
  function unbridgedTrap(typeName, base) {
    return new Proxy(Object.create(base), {
      get(inner, key, receiver) {
        if (typeof key === "symbol" || key in inner || PROBES.has(key)) return Reflect.get(inner, key, receiver);
        reportUnsupported(`${typeName}.${key}`);
        return undefined;
      },
      set(inner, key, value, receiver) {
        if (typeof key !== "symbol" && !(key in inner)) reportUnsupported(`${typeName}.${key}`);
        return Reflect.set(inner, key, value, receiver);
      },
    });
  }

  function guard(type, base) {
    Object.setPrototypeOf(type.prototype, unbridgedTrap(type.name, base));
  }

  // ------------------------------------------------------------- conversions

  /** As BluetoothUUID.getService: a 16/32-bit alias or a UUID, as a lowercase 128-bit UUID. */
  function canonicalUUID(name) {
    if (typeof name === "number" && Number.isInteger(name) && name >= 0 && name <= 0xffffffff) {
      return name.toString(16).padStart(8, "0") + BASE_UUID_TAIL;
    }
    if (typeof name === "string") {
      const lower = name.toLowerCase();
      if (FULL_UUID.test(lower)) return lower;
      const short = SHORT_UUID.exec(lower);
      if (short) return short[1].padStart(8, "0") + BASE_UUID_TAIL;
    }
    throw new TypeError(`Invalid Service name: '${String(name)}'. It must be a valid UUID alias (e.g. 0x1234) or UUID.`);
  }

  function bytesOf(value) {
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (Object.prototype.toString.call(value) === "[object ArrayBuffer]") return new Uint8Array(value);
    throw new TypeError("The value is not an ArrayBuffer, a typed array or a DataView.");
  }

  function toBase64(bytes) {
    let text = "";
    for (const byte of bytes) text += String.fromCharCode(byte);
    return btoa(text);
  }

  function fromBase64(text) {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function unsupportedOption(method) {
    reportUnsupported(method);
    return fail("NotSupportedError", `${method} is not bridged.`);
  }

  function requestOptions(options) {
    for (const key of Object.keys(options)) if (!REQUEST_KEYS.has(key)) throw unsupportedOption(`Bluetooth.requestDevice.${key}`);
    if (options.acceptAllDevices) throw unsupportedOption("Bluetooth.requestDevice.acceptAllDevices");
    if (!Array.isArray(options.filters) || options.filters.length === 0) throw new TypeError("'filters' must be a non-empty list to find any devices.");
    return {
      filters: options.filters.map(requestFilter),
      optionalServices: [...(options.optionalServices || [])].map(canonicalUUID),
    };
  }

  function requestFilter(filter) {
    const result = {};
    for (const key of Object.keys(filter)) if (!FILTER_KEYS.has(key)) throw unsupportedOption(`Bluetooth.requestDevice.filters.${key}`);
    if (filter.services !== undefined) result.services = [...filter.services].map(canonicalUUID);
    if (filter.name !== undefined) result.name = String(filter.name);
    if (filter.namePrefix !== undefined) result.namePrefix = String(filter.namePrefix);
    if (filter.manufacturerData !== undefined) {
      result.manufacturerData = [...filter.manufacturerData].map((entry) => {
        for (const key of Object.keys(entry)) if (key !== "companyIdentifier") throw unsupportedOption(`Bluetooth.requestDevice.filters.manufacturerData.${key}`);
        return { companyIdentifier: entry.companyIdentifier };
      });
    }
    if (Object.keys(result).length === 0) throw new TypeError("A filter must restrict the devices in some way.");
    return result;
  }

  // ------------------------------------------------------------------ state

  /**
   * Per device id: the page's objects and the connection state of
   * bridge-protocol.md "Connection state and timing".
   */
  const states = new Map();
  /** watchId → device, for advertisement events. */
  const watches = new Map();
  let watchCount = 0;

  function deviceFor({ id, name }) {
    let state = states.get(id);
    if (!state) {
      state = {
        id,
        name,
        connected: false,
        /** The epoch of the current connection (null while disconnected). */
        epoch: null,
        /** The highest epoch seen in a `disconnected` event. */
        highestDisconnected: -Infinity,
        /** Counts connect() and disconnect() calls, to tell superseded attempts. */
        calls: 0,
        /** The `calls` count of the latest disconnect(). */
        lastDisconnect: 0,
        pendingConnects: 0,
        /** The current connection's discovered attributes (null while disconnected); see newConnection(). */
        connection: null,
      };
      states.set(id, state);
      state.device = new BluetoothDevice(state);
      state.server = new BluetoothRemoteGATTServer(state);
    }
    return state.device;
  }

  /**
   * Services and characteristics belong to one connection, as in Web
   * Bluetooth: a reconnect discovers new objects, so listeners on the old ones
   * hear nothing more, and the old ones cannot operate on the new connection.
   */
  function newConnection() {
    return {
      services: new Map(),
      /** "service characteristic" → {object, value, properties}. */
      characteristics: new Map(),
    };
  }

  const disconnectedError = () => fail("NetworkError", "GATT Server is disconnected. Cannot perform GATT operations.");

  function requireConnected(state) {
    if (!state.connected) throw disconnectedError();
  }

  /** As Chrome: the server is checked first (NetworkError), then whether the attribute's connection is still the current one. */
  function requireCurrent(state, connection, kind) {
    requireConnected(state);
    if (connection !== state.connection) throw fail("InvalidStateError", `GATT ${kind} no longer exists.`);
  }

  /** A GATT call on `connection`; if that connection ended before the reply, it rejects with NetworkError, as in Chrome. */
  async function gattCall(state, connection, op, args) {
    const result = await call(op, args);
    if (connection !== state.connection) throw disconnectedError();
    return result;
  }

  function endConnection(state) {
    state.connected = false;
    state.epoch = null;
    state.connection = null;
    state.device.dispatchEvent(new Event("gattserverdisconnected", { bubbles: true }));
  }

  async function connect(state) {
    state.calls += 1;
    const attempt = state.calls;
    state.pendingConnects += 1;
    let value;
    let failure = null;
    try {
      value = await call("connect", { id: state.id });
    } catch (error) {
      failure = error;
    } finally {
      state.pendingConnects -= 1;
    }
    if (attempt !== state.calls) {
      // Cleanup of a success that the page disconnected meanwhile; Swift ignores it if a newer attempt began.
      if (!failure && state.lastDisconnect > attempt) call("disconnect", { id: state.id, epoch: value.epoch }).catch(() => {});
      throw fail("AbortError", "Connection attempt superseded by a later connect() or disconnect().");
    }
    if (failure) throw failure;
    if (value.epoch <= state.highestDisconnected) throw fail("NetworkError", "Disconnected while connecting.");
    // A connect while connected moves to the newer epoch on the same link: the connection and its objects stay.
    if (!state.connected) state.connection = newConnection();
    state.connected = true;
    state.epoch = value.epoch;
    return state.server;
  }

  function disconnect(state) {
    state.calls += 1;
    state.lastDisconnect = state.calls;
    if (!state.connected && state.pendingConnects === 0) return;
    call("disconnect", { id: state.id }).catch(() => {});
    if (state.connected) endConnection(state);
  }

  function serviceFor(state, connection, uuid) {
    let service = connection.services.get(uuid);
    if (!service) {
      service = new BluetoothRemoteGATTService(state, connection, uuid);
      connection.services.set(uuid, service);
    }
    return service;
  }

  function characteristicFor(state, connection, service, uuid, properties) {
    const key = `${service.uuid} ${uuid}`;
    let record = connection.characteristics.get(key);
    if (!record) {
      record = { value: null, properties: null };
      record.object = new BluetoothRemoteGATTCharacteristic(state, connection, service, uuid, record);
      connection.characteristics.set(key, record);
    }
    const flags = new Set(properties || []);
    record.properties = Object.freeze(Object.fromEntries(PROPERTY_NAMES.map((name) => [name, flags.has(name)])));
    return record.object;
  }

  // ---------------------------------------------------------------- classes

  class Bluetooth extends EventTarget {
    async requestDevice(options = {}) {
      return deviceFor(await call("requestDevice", requestOptions(options)));
    }

    async getDevices() {
      return (await call("getDevices", {})).map(deviceFor);
    }

    get pigriderBridge() {
      return bridgeInfo;
    }
  }

  class BluetoothDevice extends EventTarget {
    #state;

    constructor(state) {
      super();
      this.#state = state;
    }

    get id() {
      return this.#state.id;
    }

    get name() {
      return this.#state.name;
    }

    get gatt() {
      return this.#state.server;
    }

    async forget() {
      await call("forget", { id: this.#state.id });
    }

    async watchAdvertisements({ signal } = {}) {
      const aborted = () => fail("AbortError", "Watching advertisements was aborted.");
      if (signal && signal.aborted) throw aborted();
      watchCount += 1;
      const watchId = `w${watchCount}`;
      watches.set(watchId, this);
      const stop = () => {
        if (watches.delete(watchId)) call("unwatchAdvertisements", { watchId }).catch(() => {});
      };
      if (signal) signal.addEventListener("abort", stop, { once: true });
      try {
        await call("watchAdvertisements", { id: this.#state.id, watchId });
      } catch (error) {
        watches.delete(watchId);
        if (signal) signal.removeEventListener("abort", stop);
        throw error;
      }
      if (signal && signal.aborted) throw aborted();
    }
  }

  class BluetoothAdvertisingEvent extends Event {
    #init;

    constructor(type, init) {
      super(type);
      this.#init = init;
    }

    get device() {
      return this.#init.device;
    }

    get name() {
      return this.#init.name;
    }

    get rssi() {
      return this.#init.rssi;
    }

    get uuids() {
      return [];
    }

    get manufacturerData() {
      return new Map();
    }

    get serviceData() {
      return new Map();
    }
  }

  class BluetoothRemoteGATTServer {
    #state;

    constructor(state) {
      this.#state = state;
    }

    get device() {
      return this.#state.device;
    }

    get connected() {
      return this.#state.connected;
    }

    connect() {
      return connect(this.#state);
    }

    disconnect() {
      disconnect(this.#state);
    }

    async getPrimaryService(service) {
      const uuid = canonicalUUID(service);
      requireConnected(this.#state);
      const { connection } = this.#state;
      await gattCall(this.#state, connection, "getPrimaryService", { id: this.#state.id, service: uuid });
      return serviceFor(this.#state, connection, uuid);
    }
  }

  class BluetoothRemoteGATTService extends EventTarget {
    #state;
    #connection;
    #uuid;

    constructor(state, connection, uuid) {
      super();
      this.#state = state;
      this.#connection = connection;
      this.#uuid = uuid;
    }

    get device() {
      return this.#state.device;
    }

    get uuid() {
      return this.#uuid;
    }

    async getCharacteristic(characteristic) {
      const uuid = canonicalUUID(characteristic);
      requireCurrent(this.#state, this.#connection, "Service");
      const args = { id: this.#state.id, service: this.#uuid, characteristic: uuid };
      const { properties } = await gattCall(this.#state, this.#connection, "getCharacteristic", args);
      return characteristicFor(this.#state, this.#connection, this, uuid, properties);
    }
  }

  class BluetoothRemoteGATTCharacteristic extends EventTarget {
    #state;
    #connection;
    #service;
    #uuid;
    #record;

    constructor(state, connection, service, uuid, record) {
      super();
      this.#state = state;
      this.#connection = connection;
      this.#service = service;
      this.#uuid = uuid;
      this.#record = record;
    }

    get service() {
      return this.#service;
    }

    get uuid() {
      return this.#uuid;
    }

    get properties() {
      return this.#record.properties;
    }

    get value() {
      return this.#record.value;
    }

    async startNotifications() {
      requireCurrent(this.#state, this.#connection, "Characteristic");
      await gattCall(this.#state, this.#connection, "startNotifications", this.#address());
      return this;
    }

    writeValueWithResponse(value) {
      return this.#write(value, true);
    }

    writeValueWithoutResponse(value) {
      return this.#write(value, false);
    }

    async #write(value, withResponse) {
      const bytes = toBase64(bytesOf(value));
      requireCurrent(this.#state, this.#connection, "Characteristic");
      await gattCall(this.#state, this.#connection, "writeValue", { ...this.#address(), value: bytes, withResponse });
    }

    #address() {
      return { id: this.#state.id, service: this.#service.uuid, characteristic: this.#uuid };
    }
  }

  guard(Bluetooth, EventTarget.prototype);
  guard(BluetoothDevice, EventTarget.prototype);
  guard(BluetoothRemoteGATTServer, Object.prototype);
  guard(BluetoothRemoteGATTService, EventTarget.prototype);
  guard(BluetoothRemoteGATTCharacteristic, EventTarget.prototype);

  const bridgeInfo = Object.freeze({ version, ops: OPS });

  // ------------------------------------------------------------ native events

  function onValue(event) {
    const state = states.get(event.id);
    if (!state || !state.connected || event.epoch !== state.epoch) return;
    const record = state.connection.characteristics.get(`${event.service} ${event.characteristic}`);
    if (!record) return;
    record.value = new DataView(fromBase64(event.value).buffer);
    record.object.dispatchEvent(new Event("characteristicvaluechanged", { bubbles: true }));
  }

  function onDisconnected(event) {
    const state = states.get(event.id);
    if (!state) return;
    state.highestDisconnected = Math.max(state.highestDisconnected, event.epoch);
    // One link per device: a drop reported with a newer epoch (a connect() in flight) ends this connection too.
    if (state.connected && event.epoch >= state.epoch) endConnection(state);
  }

  function onAdvertisement(event) {
    const device = watches.get(event.watchId);
    if (!device) return;
    device.dispatchEvent(new BluetoothAdvertisingEvent("advertisementreceived", { device, name: event.name, rssi: event.rssi }));
  }

  const handlers = { value: onValue, disconnected: onDisconnected, advertisement: onAdvertisement };

  Object.defineProperty(target.navigator, "bluetooth", { value: new Bluetooth(), configurable: true, enumerable: true });
  // WebKit offers navigator.clipboard only in a secure context. Over plain HTTP at home
  // the app copies instead, like a browser: only on a tap (transient user activation).
  if (!target.navigator.clipboard) {
    const clipboard = Object.freeze({
      async writeText(data) {
        const activation = target.navigator.userActivation;
        if (!activation || !activation.isActive) throw fail("NotAllowedError", "Copying needs a tap.");
        await call("copyText", { text: String(data) });
      },
    });
    Object.defineProperty(target.navigator, "clipboard", { value: clipboard, configurable: true, enumerable: true });
  }
  Object.defineProperty(target, "__pigriderBle", {
    value: Object.freeze({
      dispatch(event) {
        const handler = event && Object.prototype.hasOwnProperty.call(handlers, event.type) ? handlers[event.type] : null;
        if (handler) handler(event);
      },
    }),
    configurable: true,
  });
}
