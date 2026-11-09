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
