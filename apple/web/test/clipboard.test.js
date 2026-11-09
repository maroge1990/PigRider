// navigator.clipboard over plain HTTP: WebKit has none outside a secure
// context, so the polyfill sends writeText to the app (op copyText).
import { test } from "node:test";
import assert from "node:assert/strict";
import { install, settle } from "./harness.js";

const tapped = { userActivation: { isActive: true } };

test("over plain HTTP, writeText sends the text to the app", async () => {
  const page = install({ navigator: tapped });
  page.channel.answer("copyText");
  await page.target.navigator.clipboard.writeText("report");
  assert.deepEqual(page.channel.messages("copyText"), [{ op: "copyText", text: "report" }]);
});

test("a page with its own clipboard (a secure context) keeps it", () => {
  const own = { writeText: async () => {} };
  const page = install({ navigator: { ...tapped, clipboard: own } });
  assert.equal(page.target.navigator.clipboard, own);
});

test("without a tap, writeText rejects with NotAllowedError and sends nothing", async () => {
  const page = install({ navigator: { userActivation: { isActive: false } } });
  await assert.rejects(page.target.navigator.clipboard.writeText("report"), { name: "NotAllowedError" });
  await settle();
  assert.deepEqual(page.channel.messages("copyText"), []);
});

test("writeText copies the text form of what it is given, as the DOMString argument does", async () => {
  const page = install({ navigator: tapped });
  page.channel.answer("copyText");
  await page.target.navigator.clipboard.writeText(42);
  assert.deepEqual(page.channel.messages("copyText"), [{ op: "copyText", text: "42" }]);
});

test("a refusal from the app rejects with its name", async () => {
  const page = install({ navigator: tapped });
  page.channel.answer("copyText", (call) => call.fail("DataError"));
  await assert.rejects(page.target.navigator.clipboard.writeText("report"), { name: "DataError" });
});

test("another origin's page gets no clipboard either", () => {
  const page = install({ pageOrigin: "http://evil.example", navigator: tapped });
  assert.equal(page.target.navigator.clipboard, undefined);
});
