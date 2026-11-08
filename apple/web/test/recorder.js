// Lists every Web Bluetooth member upstream touches: a membrane around the
// page's `bluetooth` that wraps every bridged object (and the events that
// listeners get) handed out through it, recording "Type.member" on each read.
// Calls run on the real objects, so the polyfill sees its own `this`.

/** What the bridge provides (the API subset of the BLE bridge design). */
export const BRIDGED = new Set([
  "Bluetooth.requestDevice",
  "Bluetooth.getDevices",
  "Bluetooth.pigriderBridge",
  "BluetoothDevice.id",
  "BluetoothDevice.name",
  "BluetoothDevice.gatt",
  "BluetoothDevice.watchAdvertisements",
  "BluetoothDevice.forget",
  "BluetoothDevice.addEventListener",
  "BluetoothDevice.removeEventListener",
  "BluetoothRemoteGATTServer.device",
  "BluetoothRemoteGATTServer.connected",
  "BluetoothRemoteGATTServer.connect",
  "BluetoothRemoteGATTServer.disconnect",
  "BluetoothRemoteGATTServer.getPrimaryService",
  "BluetoothRemoteGATTService.device",
  "BluetoothRemoteGATTService.uuid",
  "BluetoothRemoteGATTService.getCharacteristic",
  "BluetoothRemoteGATTCharacteristic.service",
  "BluetoothRemoteGATTCharacteristic.uuid",
  "BluetoothRemoteGATTCharacteristic.properties",
  "BluetoothRemoteGATTCharacteristic.value",
  "BluetoothRemoteGATTCharacteristic.startNotifications",
  "BluetoothRemoteGATTCharacteristic.writeValueWithResponse",
  "BluetoothRemoteGATTCharacteristic.writeValueWithoutResponse",
  "BluetoothRemoteGATTCharacteristic.addEventListener",
  "BluetoothRemoteGATTCharacteristic.removeEventListener",
  "BluetoothAdvertisingEvent.device",
  "BluetoothAdvertisingEvent.name",
  "BluetoothAdvertisingEvent.rssi",
  "Event.target",
]);

const TYPES = new Set([
  "Bluetooth",
  "BluetoothDevice",
  "BluetoothRemoteGATTServer",
  "BluetoothRemoteGATTService",
  "BluetoothRemoteGATTCharacteristic",
  "BluetoothAdvertisingEvent",
  "Event",
]);
const PROBES = new Set(["then", "toJSON", "inspect", "constructor"]);

export function recorder() {
  const touched = new Set();
  const wrappers = new WeakMap();
  const listeners = new WeakMap();

  const typeOf = (value) => (value !== null && typeof value === "object" && TYPES.has(value.constructor?.name) ? value.constructor.name : null);

  function wrapResult(result) {
    if (result && typeof result.then === "function") return result.then(wrapResult);
    return Array.isArray(result) ? result.map(wrap) : wrap(result);
  }

  function listenerFor(listener) {
    if (typeof listener !== "function") return listener;
    if (!listeners.has(listener)) listeners.set(listener, function (event) {
      return listener.call(wrap(event.currentTarget), wrap(event));
    });
    return listeners.get(listener);
  }

  function wrap(raw) {
    const type = typeOf(raw);
    if (!type) return raw;
    if (!wrappers.has(raw)) {
      wrappers.set(
        raw,
        new Proxy(raw, {
          get(object, key) {
            if (typeof key === "symbol" || PROBES.has(key)) return Reflect.get(object, key, object);
            touched.add(`${type}.${key}`);
            const value = Reflect.get(object, key, object);
            if (typeof value !== "function") return wrap(value);
            return (...args) => {
              if (key === "addEventListener" || key === "removeEventListener") args[1] = listenerFor(args[1]);
              return wrapResult(value.apply(object, args));
            };
          },
        }),
      );
    }
    return wrappers.get(raw);
  }

  return {
    touched,
    wrap,
    outsideBridged: () => [...touched].filter((member) => !BRIDGED.has(member)).sort(),
  };
}
