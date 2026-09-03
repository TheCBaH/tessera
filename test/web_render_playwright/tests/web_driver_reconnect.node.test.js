// The resync/reconnect recovery test (see lib/proxy_linux/web_server.mli's "Reconnect/resync
// model"): plain `node --test`, no browser, driving a
// **real** spawned `tessera-proxy` (via node-pty -- tessera-proxy needs a real controlling terminal to
// start at all, confirmed empirically; a plain `child_process.spawn` with pipes fails at startup) and a
// **real** `ws` WebSocket client against it, feeding received frames into a **real** `web/tessera-driver.js`
// `TesseraDriver` instance (require'd directly, the same way driver.node.test.js does against a fake
// target -- a native OCaml test cannot instantiate the JS driver, and Playwright is unnecessarily heavy for
// a test with no rendering/screenshot assertions).
//
// The outcome/generation counter is cumulative for the whole proxy session, not per-connection, and a
// single `pty.write` can produce more than one outcome (the inner pty's own kernel echo, plus `cat`'s own
// write-back) -- so this test never assumes "the next delta is generation N+1" by writing-then-grabbing-
// one-message. Instead every message received on a connection is queued in arrival order, and the test
// explicitly decides, message by message, whether to feed it to the driver -- which is also exactly the
// mechanism used to deliberately force `awaitingReset` (skip exactly one queued delta on purpose).
//
// Deliberately forces `awaitingReset` client-side this way, sends `Resync`, observes the real
// server-side close (no corrective frame), opens a **new** `ws` connection with a **new**
// `TesseraDriver` instance (mirroring `web/proxy-web.js`'s own close+reconnect), and asserts the fresh
// Reset is accepted and subsequent deltas render correctly.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const WebSocket = require('ws');
const { spawnProxy, killProxy } = require('./lib/spawn_proxy.js');

const { TesseraDriver } = require(path.join(__dirname, '..', '..', '..', 'web', 'tessera-driver.js'));

const CONTROL_SCHEMA = 'tessera.proxy-web';
const WEB_FRAME_SCHEMA = 'tessera.web-frame';

// A minimal recording target, matching driver.node.test.js's own `fakeTarget()`: no DOM, just call
// recording -- structural/behavioral assertions only, which is all this layer needs (Playwright already
// covers real-DOM rendering).
function fakeTarget() {
  const calls = [];
  return {
    calls,
    mount() {
      calls.push(['mount']);
    },
    reset(frame) {
      calls.push(['reset', frame]);
    },
    draw(frame, dirtyRows) {
      calls.push(['draw', frame, dirtyRows]);
    },
    setMetrics() {
      calls.push(['setMetrics']);
    },
    dispose() {
      calls.push(['dispose']);
    },
  };
}

function newId() {
  return Math.random().toString(36).slice(2);
}

function sendControl(ws, body) {
  ws.send(JSON.stringify(Object.assign({ schema: CONTROL_SCHEMA, version: 2 }, body)));
}

function waitForOpen(ws) {
  return new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
}

function waitForClose(ws, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timed out waiting for close')), timeoutMs);
    ws.once('close', (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
}

// An in-order queue of every parsed message this socket has received, with an async `next()` that waits
// for one to arrive if the queue is currently empty -- so the test can deterministically pop messages one
// at a time regardless of how many arrived in a burst, rather than racing a fresh listener against
// whatever the socket happens to deliver next.
function queueMessages(ws) {
  const pending = [];
  const waiters = [];
  ws.on('message', (data) => {
    let parsed;
    try {
      parsed = JSON.parse(data.toString('utf8'));
    } catch (err) {
      return;
    }
    if (waiters.length > 0) waiters.shift()(parsed);
    else pending.push(parsed);
  });
  return {
    next(timeoutMs = 5000) {
      if (pending.length > 0) return Promise.resolve(pending.shift());
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timed out waiting for the next message')), timeoutMs);
        waiters.push((m) => {
          clearTimeout(timer);
          resolve(m);
        });
      });
    },
    async nextMatching(predicate, timeoutMs = 5000) {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) throw new Error('timed out waiting for a matching message');
        const m = await this.next(remaining);
        if (predicate(m)) return m;
      }
    },
  };
}

test('resync forces a close+reconnect, and a fresh driver instance accepts the new lineage', async (t) => {
  const { proc, port, token } = await spawnProxy({ token: 'reconnect-test-token' });
  t.after(() => killProxy(proc));
  const sessionUrl = `ws://127.0.0.1:${port}/session?token=${token}`;

  // --- first connection: hello, reset, several accepted deltas, then a deliberately dropped one ---
  const ws1 = new WebSocket(sessionUrl);
  await waitForOpen(ws1);
  const queue1 = queueMessages(ws1);
  sendControl(ws1, { type: 'hello', id: newId(), target: 'html' });
  const ready1 = await queue1.nextMatching((m) => m.schema === CONTROL_SCHEMA && m.type === 'ready');
  assert.equal(ready1.capabilities.observe, true);

  const target1 = fakeTarget();
  const resyncs1 = [];
  const driver1 = new TesseraDriver(target1, { onResyncNeeded: (reason, details) => resyncs1.push({ reason, details }) });

  // Nudge the child (`cat`, echoing under the inner pty's own kernel line discipline) to produce real
  // terminal output, which the proxy ingests into a real Tessera.outcome and the web publisher turns
  // into frames. A single write can produce more than one outcome (kernel echo, then cat's own
  // write-back), so every web-frame message received is fed to the driver, in order, without skipping,
  // to keep it perfectly in sync with the wire.
  const feedNextFrame = async (queue, driver) => {
    const frame = await queue.nextMatching((m) => m.schema === WEB_FRAME_SCHEMA);
    driver.ingest(JSON.stringify(frame));
    return frame;
  };

  proc.write('first\r\n');
  const reset1 = await feedNextFrame(queue1, driver1);
  assert.equal(reset1.meta.kind, 'reset');
  assert.equal(driver1.awaitingReset, false);
  assert.equal(target1.calls[0][0], 'reset');
  const lineage1 = driver1.trackedLineageId;

  proc.write('second\r\n');
  await feedNextFrame(queue1, driver1);
  assert.equal(driver1.awaitingReset, false);
  assert.equal(target1.calls[target1.calls.length - 1][0], 'draw');

  // Deliberately drop exactly one queued frame (received, but never fed to the driver) -- the driver's
  // own tracked generation now lags the wire by (at least) one, so the *next* frame it does see is
  // guaranteed to violate `generation === trackedGeneration + 1`.
  proc.write('third\r\n');
  const dropped = await queue1.nextMatching((m) => m.schema === WEB_FRAME_SCHEMA);
  assert.equal(dropped.meta.kind, 'delta');

  proc.write('fourth\r\n');
  const skewed = await queue1.nextMatching((m) => m.schema === WEB_FRAME_SCHEMA);
  driver1.ingest(JSON.stringify(skewed));
  assert.equal(driver1.awaitingReset, true);
  assert.equal(resyncs1.length, 1);
  assert.equal(resyncs1[0].reason, 'generation-gap');

  // --- proxy-web.js's own contract: on resync-needed, send Resync then close; the server replies
  // Result and closes with no corrective frame (web_server.mli's documented, tested contract). ---
  sendControl(ws1, { type: 'resync', id: newId() });
  const result1 = await queue1.nextMatching((m) => m.schema === CONTROL_SCHEMA && m.type === 'result');
  assert.ok(result1.id);
  await waitForClose(ws1);

  // --- second connection: a brand-new socket *and* a brand-new TesseraDriver -- exactly what
  // web/proxy-web.js does on its own `close` handler. The fresh driver has no tracked lineage at all, so
  // it accepts the new Reset unconditionally regardless of the old driver's stuck generation. ---
  const ws2 = new WebSocket(sessionUrl);
  await waitForOpen(ws2);
  const queue2 = queueMessages(ws2);
  sendControl(ws2, { type: 'hello', id: newId(), target: 'html' });
  const ready2 = await queue2.nextMatching((m) => m.schema === CONTROL_SCHEMA && m.type === 'ready');
  assert.notEqual(ready2.id, ready1.id);

  const target2 = fakeTarget();
  const driver2 = new TesseraDriver(target2, {});
  assert.equal(driver2.trackedLineageId, null);

  proc.write('fifth\r\n');
  const reset2 = await feedNextFrame(queue2, driver2);
  assert.equal(reset2.meta.kind, 'reset');
  assert.equal(driver2.awaitingReset, false);
  assert.equal(target2.calls[0][0], 'reset');
  // Lineage is unchanged across a resync (the same proxy session, no new outcome-generation restart) --
  // only the *connection*, not the publisher's underlying lineage, was reset.
  assert.equal(driver2.trackedLineageId, lineage1);

  proc.write('sixth\r\n');
  await feedNextFrame(queue2, driver2);
  assert.equal(driver2.awaitingReset, false);
  assert.equal(target2.calls[target2.calls.length - 1][0], 'draw');

  ws2.close();
});
