/**
 * Talks to the server's intervals.icu upload route. The server holds the
 * operator's API key, so every upload goes to that one account (meant for a
 * private server with one rider). `fetch` is injected for tests.
 */

export const intervalsActivityUrl = (id) => `https://intervals.icu/activities/${encodeURIComponent(id)}`;

/** The finish screen offers the upload where the server has a key and a trainer measured the ride. */
export const offersIntervalsUpload = (info, measured) => Boolean(info?.intervals?.enabled) && measured;

export class IntervalsClient {
  /** @param {{fetch?: typeof fetch}} [deps] */
  constructor({ fetch: fetchFn = (...args) => globalThis.fetch(...args) } = {}) {
    this.fetch = fetchFn;
  }

  /** Uploads a FIT ride; resolves with `{activity_id}` (null when intervals.icu named none). */
  async upload(fit, name) {
    const response = await this.fetch(`/api/intervals/upload?name=${encodeURIComponent(name)}`, {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/vnd.ant.fit" },
      body: fit,
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.message ?? `HTTP ${response.status}`);
    return body;
  }
}

/**
 * Uploads a finished ride and reports how it went with `report(state)`:
 * `{step: "uploading"}`, then `{step: "done", id}` (id may be null) or
 * `{step: "failed", message}`. The rider may have started another ride by
 * the time intervals.icu answers, so the answer counts only while
 * `stillCurrent()`: then a success calls `kept()`; otherwise it is dropped.
 */
export async function uploadFinishedRide({ client, fit, name, stillCurrent, kept, report }) {
  report({ step: "uploading" });
  try {
    const { activity_id: id = null } = await client.upload(fit, name);
    if (!stillCurrent()) return;
    kept();
    report({ step: "done", id });
  } catch (error) {
    if (stillCurrent()) report({ step: "failed", message: error.message });
  }
}
