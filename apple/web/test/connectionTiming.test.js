// bridge-protocol.md "Connection state and timing": replies and events travel
// on different channels, so each rule is tested with both arrival orders.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEVICE, connected, disconnected, settle, withDevice } from "./harness.js";

/** Starts a connect; `reply(epoch)` answers it later. */
function startConnect(page) {
  const result = page.device.gatt.connect().then(
    (server) => ({ server }),
    (error) => ({ error }),
  );
  const call = page.channel.pending("connect").at(-1);
  return { result, ok: (epoch) => call.ok({ epoch }), fail: (name) => call.fail(name) };
}

function recordDisconnects(page) {
  const fired = [];
  page.device.addEventListener("gattserverdisconnected", () => fired.push("gattserverdisconnected"));
  return fired;
}

// ------------------------------------------------------------ disconnect wins

test("disconnected for epoch E before the connect reply for E: connect rejects with NetworkError", async () => {
  const page = await withDevice();
  const attempt = startConnect(page);
  page.dispatch(disconnected(4));
  attempt.ok(4);
  assert.equal((await attempt.result).error?.name, "NetworkError");
});

test("disconnected for epoch E before the connect reply for E: gatt.connected stays false", async () => {
  const page = await withDevice();
  const attempt = startConnect(page);
  page.dispatch(disconnected(4));
  attempt.ok(4);
  await attempt.result;
  assert.equal(page.device.gatt.connected, false);
});

test("disconnected for epoch E before the connect reply for E: no gattserverdisconnected (it never connected)", async () => {
  const page = await withDevice();
  const fired = recordDisconnects(page);
  const attempt = startConnect(page);
  page.dispatch(disconnected(4));
  attempt.ok(4);
  await attempt.result;
  assert.deepEqual(fired, []);
});

test("the connect reply for E before disconnected for E: connect resolves, then the connection ends", async () => {
  const page = await withDevice();
  const fired = recordDisconnects(page);
  const attempt = startConnect(page);
  attempt.ok(4);
  assert.equal((await attempt.result).server, page.device.gatt);
  page.dispatch(disconnected(4));
  assert.deepEqual([fired, page.device.gatt.connected], [["gattserverdisconnected"], false]);
});

test("a drop of an older connection does not fail a newer connect", async () => {
  const page = await withDevice();
  page.dispatch(disconnected(3));
  const attempt = startConnect(page);
  attempt.ok(4);
  await attempt.result;
  assert.equal(page.device.gatt.connected, true);
});

// ---------------------------------------------- disconnect() during a connect

async function disconnectedDuringConnect() {
  const page = await withDevice();
  const attempt = startConnect(page);
  page.device.gatt.disconnect();
  return { page, attempt };
}

test("disconnect() during a connect: a late success rejects with AbortError", async () => {
  const { attempt } = await disconnectedDuringConnect();
  attempt.ok(4);
  assert.equal((await attempt.result).error?.name, "AbortError");
});

test("disconnect() during a connect: a late success leaves gatt.connected false", async () => {
  const { page, attempt } = await disconnectedDuringConnect();
  attempt.ok(4);
  await attempt.result;
  assert.equal(page.device.gatt.connected, false);
});

test("disconnect() during a connect cancels it on the native side, without an epoch", async () => {
  const { page } = await disconnectedDuringConnect();
  assert.deepEqual(page.channel.messages("disconnect"), [{ op: "disconnect", id: DEVICE.id }]);
});

test("disconnect() during a connect: a late success is cleaned up with a disconnect carrying that reply's epoch", async () => {
  const { page, attempt } = await disconnectedDuringConnect();
  attempt.ok(4);
  await attempt.result;
  assert.deepEqual(page.channel.messages("disconnect").at(-1), { op: "disconnect", id: DEVICE.id, epoch: 4 });
});

test("disconnect() during a connect: a late failure rejects with AbortError and needs no cleanup", async () => {
  const { page, attempt } = await disconnectedDuringConnect();
  attempt.fail("NetworkError");
  assert.deepEqual([(await attempt.result).error?.name, page.channel.messages("disconnect").length], ["AbortError", 1]);
});

test("disconnect() during a connect, then the native drop before the late success: still AbortError", async () => {
  const { page, attempt } = await disconnectedDuringConnect();
  page.dispatch(disconnected(4));
  attempt.ok(4);
  assert.equal((await attempt.result).error?.name, "AbortError");
});

// ------------------------------------------------------ superseded attempts

test("a newer connect() supersedes an older one: the older reply rejects with AbortError", async () => {
  const page = await withDevice();
  const older = startConnect(page);
  const newer = startConnect(page);
  older.ok(4);
  newer.ok(5);
  assert.equal((await older.result).error?.name, "AbortError");
});

test("a newer connect() supersedes an older one: the newer reply connects, in either order", async () => {
  for (const order of [["older", "newer"], ["newer", "older"]]) {
    const page = await withDevice();
    const attempts = { older: startConnect(page), newer: startConnect(page) };
    for (const name of order) attempts[name].ok(name === "older" ? 4 : 5);
    await Promise.all([attempts.older.result, attempts.newer.result]);
    assert.equal(page.device.gatt.connected, true, order.join(" then "));
  }
});

test("a connect superseded by another connect sends no cleanup disconnect", async () => {
  const page = await withDevice();
  const older = startConnect(page);
  startConnect(page).ok(5);
  older.ok(4);
  await older.result;
  assert.deepEqual(page.channel.messages("disconnect"), []);
});

async function lateSuccessAfterNewerConnection() {
  const page = await withDevice();
  const a = startConnect(page);
  page.device.gatt.disconnect();
  const b = startConnect(page);
  b.ok(5);
  await b.result;
  a.ok(4);
  await a.result;
  await settle();
  return page;
}

test("attempt A succeeding late after attempt B connected leaves B connected", async () => {
  const page = await lateSuccessAfterNewerConnection();
  assert.equal(page.device.gatt.connected, true);
});

test("attempt A succeeding late after attempt B connected: the cleanup carries A's epoch, so it cannot cut B", async () => {
  const page = await lateSuccessAfterNewerConnection();
  assert.deepEqual(page.channel.messages("disconnect").at(-1), { op: "disconnect", id: DEVICE.id, epoch: 4 });
});

test("attempt A succeeding late after attempt B connected: B's values still arrive", async () => {
  const page = await lateSuccessAfterNewerConnection();
  const characteristic = await (await page.device.gatt.getPrimaryService(0x1826)).getCharacteristic(0x2ad2);
  let values = 0;
  characteristic.addEventListener("characteristicvaluechanged", () => (values += 1));
  page.dispatch({ type: "value", id: DEVICE.id, epoch: 5, service: characteristic.service.uuid, characteristic: characteristic.uuid, value: "AQ==" });
  assert.equal(values, 1);
});

test("the drop of a superseded attempt's epoch does not end the newer connection", async () => {
  const page = await lateSuccessAfterNewerConnection();
  page.dispatch(disconnected(4));
  assert.equal(page.device.gatt.connected, true);
});

// --------------------------------------------------------- reconnecting

test("after a drop, the next connect with a newer epoch connects again", async () => {
  const page = await connected(await withDevice(), 4);
  page.dispatch(disconnected(4));
  await connected(page, 5);
  assert.equal(page.device.gatt.connected, true);
});
