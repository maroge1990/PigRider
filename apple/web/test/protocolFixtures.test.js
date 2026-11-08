import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const fixtures = JSON.parse(read("./fixtures/protocol.json"));
const protocolDoc = read("../../docs/bridge-protocol.md");
const bridgeVersion = Number(read("../../BRIDGE_VERSION").trim());

test("fixtures cover every op listed in bridge-protocol.md", () => {
  const documented = [...protocolDoc.matchAll(/^\| `(\w+)` \|/gm)].map((match) => match[1]).filter((name) => !["value", "disconnected", "advertisement"].includes(name));
  assert.deepEqual([...documented].sort(), [...fixtures.ops].sort());
});

test("every op has at least one valid call fixture", () => {
  const used = new Set(fixtures.calls.filter((call) => call.valid).map((call) => call.message.op));
  assert.deepEqual(fixtures.ops.filter((op) => !used.has(op)), []);
});

test("invalid call fixtures name a known error", () => {
  for (const call of fixtures.calls.filter((entry) => !entry.valid)) assert.ok(fixtures.errorNames.includes(call.error), call.name);
});

test("fixtures are for the current bridge version", () => {
  assert.equal(fixtures.version, bridgeVersion);
});
