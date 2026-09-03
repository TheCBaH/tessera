// End-to-end browser coverage for the real served page: spawns a real
// `tessera-proxy` (via node-pty -- see tests/lib/spawn_proxy.js) against the fixed, deterministic
// `/bin/cat` child, loads the real bootstrap URL (http://127.0.0.1:<port>/?token=...) in a headless
// Chromium context, and asserts the document, every static subresource, and the token-gated /session
// upgrade all succeed under the real credential flow end to end, and that real terminal output typed
// into the child renders in the mounted `.tessera-frame`.
//
// This spec deliberately does not compare against test/web_rendering_traces' committed goldens: those
// are captured from a completely different path (a native/JSOO/Melange replay of a fixed trace through
// Bridge_runner), not from a live tessera-proxy session relaying a real, only-loosely-deterministic PTY
// round trip (the exact byte-for-byte timing of the kernel line discipline's own echo is not something
// this test controls). Structural/content assertions against what was actually typed are the right
// oracle here, not an unrelated golden fixture.
//
// A second test drives web/proxy-web.js's reconnect/generation logic directly (DOM-dependent --
// `.tessera-frame` element counting -- in a way the plain-Node layer cannot exercise): forces a
// WebSocket error immediately followed by close on the live socket and asserts exactly one reconnect
// happens (the publisher's client count goes 1 -> 0 -> 1, never 2 concurrently) and exactly one
// `.tessera-frame` element is present afterward (no leaked stale node from the old TesseraHtmlTarget).

'use strict';

const { test, expect } = require('@playwright/test');
const { spawnProxy, killProxy } = require('./lib/spawn_proxy.js');

test('the served page, its static subresources, and the token-gated /session upgrade all succeed, and typed output renders', async ({
  page,
}) => {
  const { proc, bootstrapUrl } = await spawnProxy({ token: 'playwright-test-token' });
  try {
    const responses = [];
    page.on('response', (response) => responses.push({ url: response.url(), status: response.status() }));
    const consoleErrors = [];
    page.on('pageerror', (error) => consoleErrors.push(String(error)));

    await page.goto(bootstrapUrl);
    await expect(page).toHaveTitle('tessera-proxy');

    for (const assetPath of [
      '/',
      '/tessera.css',
      '/tessera-decode.js',
      '/tessera-driver.js',
      '/tessera-html-target.js',
      '/proxy-web.js',
      '/fonts/jetbrains-mono-latin-400-normal.woff2',
    ]) {
      const matching = responses.filter((r) => new URL(r.url).pathname === assetPath);
      expect(matching.length, `expected exactly one response for ${assetPath}`).toBeGreaterThan(0);
      for (const r of matching) expect(r.status, `${assetPath} responded ${r.status}`).toBe(200);
    }

    // The real @font-face actually resolved and loaded -- not just that the CSS bytes arrived, but that
    // the browser could use the face by the time proxy-web.js's own connect() measured cell metrics from it.
    const fontLoaded = await page.evaluate(async () => {
      await document.fonts.ready;
      return document.fonts.check('400 16px "Tessera Mono"');
    });
    expect(fontLoaded).toBe(true);

    // A live /session upgrade + hello/reset exchange is proven end to end by real typed content showing
    // up in the mounted frame -- not by inspecting WebSocket handshake headers directly (Playwright has
    // no first-class API for that), which is a stronger, behavioral proof anyway.
    await expect(page.locator('.tessera-frame')).toHaveCount(1);
    proc.write('hello playwright\r\n');
    await expect(page.locator('.tessera-frame')).toContainText('hello playwright', { timeout: 5000 });

    expect(consoleErrors).toEqual([]);
  } finally {
    killProxy(proc);
  }
});

test('an error-then-close on the live socket causes exactly one reconnect, with no leaked DOM node', async ({
  page,
}) => {
  const { proc, bootstrapUrl } = await spawnProxy({ token: 'playwright-reconnect-token' });
  try {
    // proxy-web.js keeps its live WebSocket in a closed-over local (by design -- it exposes no public
    // reference). Installed before navigation, this records every constructed socket on `window`, so the
    // test can dispatch synthetic events on the *real* current instance without proxy-web.js needing to
    // change at all.
    await page.addInitScript(() => {
      window.__sockets = [];
      const OriginalWebSocket = window.WebSocket;
      window.WebSocket = class extends OriginalWebSocket {
        constructor(...args) {
          super(...args);
          window.__sockets.push(this);
        }
      };
    });

    await page.goto(bootstrapUrl);
    await expect(page.locator('.tessera-frame')).toHaveCount(1);
    proc.write('before reconnect\r\n');
    await expect(page.locator('.tessera-frame')).toContainText('before reconnect', { timeout: 5000 });
    const socketCountBefore = await page.evaluate(() => window.__sockets.length);

    // The exact hazard proxy-web.js's own doc comment names: an `error` event immediately followed by
    // `close` must still yield exactly one reconnect, not two, because *only* the `close` handler ever
    // tears down/reconnects (`onerror` just closes the socket, which always produces its own `close`).
    await page.evaluate(() => {
      const ws = window.__sockets[window.__sockets.length - 1];
      ws.dispatchEvent(new Event('error'));
      ws.close();
    });

    // A fresh WebSocket is constructed (the reconnect), against the *same* page location/token, so it
    // reaches the same still-running tessera-proxy and completes a real hello/ready/reset round trip.
    await expect.poll(() => page.evaluate(() => window.__sockets.length), { timeout: 5000 }).toBe(socketCountBefore + 1);
    await expect(page.locator('.tessera-frame')).toHaveCount(1);
    proc.write('after reconnect\r\n');
    await expect(page.locator('.tessera-frame')).toContainText('after reconnect', { timeout: 5000 });

    // Exactly one reconnect: no second socket sneaks in from a duplicated error-then-close handling path.
    await page.waitForTimeout(700); // past RECONNECT_BACKOFF_MS, so a stray second reconnect would show up
    expect(await page.evaluate(() => window.__sockets.length)).toBe(socketCountBefore + 1);
  } finally {
    killProxy(proc);
  }
});
