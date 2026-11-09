import { test } from "node:test";
import assert from "node:assert/strict";
import { IntervalsClient, intervalsActivityUrl, offersIntervalsUpload, uploadFinishedRide } from "../public/js/net/intervals.js";

const reply = (status, body) => ({ ok: status < 400, status, json: async () => body });

function client(responses) {
  const calls = [];
  const fetch = async (url, options = {}) => {
    calls.push({ url, ...options });
    return responses.shift();
  };
  return { intervals: new IntervalsClient({ fetch }), calls };
}

test("upload posts the FIT file with its type and name, and resolves with the activity id", async () => {
  const { intervals, calls } = client([reply(200, { activity_id: "i42" })]);
  const fit = new Uint8Array([14, 0x20]);
  const done = await intervals.upload(fit, "OpenRadlr · Rolling Hills");
  assert.equal(done.activity_id, "i42");
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].url, "/api/intervals/upload?name=OpenRadlr%20%C2%B7%20Rolling%20Hills");
  assert.equal(calls[0].headers["content-type"], "application/vnd.ant.fit");
  assert.equal(calls[0].credentials, "same-origin");
  assert.equal(calls[0].body, fit);
});

test("upload errors carry the server's message", async () => {
  const { intervals } = client([reply(502, { code: "intervals_key_rejected", message: "the server's intervals.icu key was refused" })]);
  await assert.rejects(intervals.upload(new Uint8Array([1]), "Ride"), { message: "the server's intervals.icu key was refused" });
});

test("an error without a message names the HTTP status", async () => {
  const { intervals } = client([{ ok: false, status: 500, json: async () => { throw new Error("not json"); } }]);
  await assert.rejects(intervals.upload(new Uint8Array([1]), "Ride"), { message: "HTTP 500" });
});

test("activities link to intervals.icu", () => {
  assert.equal(intervalsActivityUrl("i42"), "https://intervals.icu/activities/i42");
  assert.equal(intervalsActivityUrl("a/b"), "https://intervals.icu/activities/a%2Fb");
});

test("the upload is offered for trainer rides on a server with intervals.icu", () => {
  const on = { intervals: { enabled: true } };
  assert.equal(offersIntervalsUpload(on, true), true);
  assert.equal(offersIntervalsUpload(on, false), false);
  assert.equal(offersIntervalsUpload({ intervals: { enabled: false } }, true), false);
  // Older servers have no `intervals` in /api/info.
  assert.equal(offersIntervalsUpload({}, true), false);
  assert.equal(offersIntervalsUpload(null, true), false);
});

/** An upload that answers when the test says so. */
function pendingUpload() {
  let settle;
  const answer = new Promise((resolve, reject) => { settle = { resolve, reject }; });
  return { client: { upload: () => answer }, settle };
}

function ride(client) {
  const steps = [];
  let kept = 0;
  const state = { current: true };
  const done = uploadFinishedRide({
    client, fit: new Uint8Array([1]), name: "Ride",
    stillCurrent: () => state.current, kept: () => { kept += 1; }, report: (step) => steps.push(step),
  });
  return { steps, kept: () => kept, state, done };
}

test("a finished upload keeps the ride and reports the activity", async () => {
  const { client, settle } = pendingUpload();
  const upload = ride(client);
  assert.deepEqual(upload.steps, [{ step: "uploading" }]);
  settle.resolve({ activity_id: "i42" });
  await upload.done;
  assert.equal(upload.kept(), 1);
  assert.deepEqual(upload.steps.at(-1), { step: "done", id: "i42" });
});

test("a failed upload reports why and keeps nothing", async () => {
  const { client, settle } = pendingUpload();
  const upload = ride(client);
  settle.reject(new Error("intervals.icu is busy"));
  await upload.done;
  assert.equal(upload.kept(), 0);
  assert.deepEqual(upload.steps.at(-1), { step: "failed", message: "intervals.icu is busy" });
});

test("an upload that finishes after the next ride started leaves that ride alone", async () => {
  const { client, settle } = pendingUpload();
  const upload = ride(client);
  upload.state.current = false; // back to the menu, next ride started
  settle.resolve({ activity_id: "i42" });
  await upload.done;
  assert.equal(upload.kept(), 0);
  assert.deepEqual(upload.steps, [{ step: "uploading" }]);
});

test("a late failure is not shown on the next ride either", async () => {
  const { client, settle } = pendingUpload();
  const upload = ride(client);
  upload.state.current = false;
  settle.reject(new Error("timeout"));
  await upload.done;
  assert.deepEqual(upload.steps, [{ step: "uploading" }]);
});
