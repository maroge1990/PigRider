// The recorder behind the upstream contract test: it must see what is read
// through the objects it hands out, and flag what the bridge lacks.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEVICE, connected, withDevice } from "./harness.js";
import { recorder } from "./recorder.js";

async function recordedDevice() {
  const page = await withDevice();
  const record = recorder();
  const bluetooth = record.wrap(page.bluetooth);
  page.channel.answer("getDevices", [DEVICE]);
  const [device] = await bluetooth.getDevices();
  return { page, record, device };
}

test("the recorder lists members read through the objects it hands out, by type", async () => {
  const { record, device } = await recordedDevice();
  void device.gatt.connected;
  assert.deepEqual([...record.touched].sort(), ["Bluetooth.getDevices", "BluetoothDevice.gatt", "BluetoothRemoteGATTServer.connected"]);
});

test("the recorder flags a member outside the bridged set", async () => {
  const { record, device } = await recordedDevice();
  void device.watchingAdvertisements;
  assert.deepEqual(record.outsideBridged(), ["BluetoothDevice.watchingAdvertisements"]);
});

test("the recorder follows events to their target", async () => {
  const { page, record, device } = await recordedDevice();
  await connected(page);
  const characteristic = await (await device.gatt.getPrimaryService(0x1826)).getCharacteristic(0x2ad2);
  characteristic.addEventListener("characteristicvaluechanged", (event) => void event.target.value);
  page.dispatch({ type: "value", id: DEVICE.id, epoch: 4, service: characteristic.service.uuid, characteristic: characteristic.uuid, value: "AQ==" });
  assert.ok(record.touched.has("BluetoothRemoteGATTCharacteristic.value"));
});

test("a listener added through the recorder is removed through it", async () => {
  const { page, device } = await recordedDevice();
  await connected(page);
  let fired = 0;
  const listener = () => (fired += 1);
  device.addEventListener("gattserverdisconnected", listener);
  device.removeEventListener("gattserverdisconnected", listener);
  device.gatt.disconnect();
  assert.equal(fired, 0);
});
