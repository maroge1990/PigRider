import { test } from "node:test";
import assert from "node:assert/strict";
import { IntervalsClient, intervalsActivityUrl, offersIntervalsUpload } from "../public/js/net/intervals.js";

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
