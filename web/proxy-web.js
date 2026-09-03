// The browser side of the proxy-web transport: reads `token` from the page URL, opens the
// `tessera.proxy-web` control channel + `tessera.web-frame` payload stream that `tessera-proxy`'s
// Web_server multiplexes over one `/session` WebSocket, and drives a TesseraDriver+TesseraHtmlTarget
// pair (web/tessera-driver.js, web/tessera-html-target.js) from the frames it receives.
//
// Reconnect/generation design (see lib/proxy_linux/web_server.mli's own doc comment for the
// server-side half of this contract): one monotonic `generation` counter and one `current` record
// (`{generation, ws, driver, target}`) so a reconnect can never leak DOM or fire twice.
//  - `connect()` increments `generation`, captures its own `gen`, creates a *fresh* TesseraHtmlTarget
//    (mounted) and a *fresh* TesseraDriver wrapping it, opens a new WebSocket, and sets `current`.
//  - Every WS event handler first checks `current && current.generation === gen`; a stale event from
//    an already-superseded socket is ignored outright.
//  - `onerror` never disposes or reconnects by itself -- it only closes the still-current socket,
//    which always produces a `close` event; *all* teardown/reconnect logic lives in exactly one place,
//    the `close` handler, so an error-then-close pair still yields exactly one reconnect, not two.
//  - `driver.onResyncNeeded`/`driver.onProtocolError` (checked against `gen` the same way): send a
//    `resync` control message best-effort, then close the still-current socket -- again routed through
//    the single `close` handler, not a second teardown path.
//  - The `close` handler is the *only* teardown path, guarded by a `reconnectScheduled` single-flight
//    flag: if `current` still belongs to `gen`, it clears `current`, disposes the driver exactly once
//    (which disposes the mounted target, removing its `.tessera-frame` element), then, only if a
//    reconnect is not already scheduled, schedules one after a short backoff.

(function () {
  'use strict';

  var CONTROL_SCHEMA = 'tessera.proxy-web';
  var CONTROL_VERSION = 1;
  var WEB_FRAME_SCHEMA = 'tessera.web-frame';
  var RECONNECT_BACKOFF_MS = 500;
  var DEFAULT_METRICS = { cellWidth: 9, cellHeight: 18, lineHeight: 18, fontFamily: 'Tessera Mono', fontWeight: 400 };

  function randomId() {
    return Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  function tokenFromLocation() {
    var params = new URLSearchParams(window.location.search);
    return params.get('token') || '';
  }

  function sessionUrl(token) {
    var proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    return proto + '//' + window.location.host + '/session?token=' + encodeURIComponent(token);
  }

  // Best-effort: the socket may already be closing by the time this is called (e.g. sent from
  // onResyncNeeded right before we close it ourselves), and a send on a closing/closed socket throws.
  function sendControlMessage(ws, body) {
    try {
      ws.send(JSON.stringify(Object.assign({ schema: CONTROL_SCHEMA, version: CONTROL_VERSION }, body)));
    } catch (err) {
      /* ignored: the connection is going away regardless */
    }
  }

  var cachedMetrics = null;

  // Measures one cell's real pixel size from the loaded "Tessera Mono" face, matching how
  // TesseraHtmlTarget.setMetrics expects (cellWidth/cellHeight/lineHeight in pixels): a probe element
  // is more reliable across browsers than assuming a fixed advance width for a monospace face.
  function measureMetrics() {
    if (cachedMetrics) return cachedMetrics;
    if (typeof document === 'undefined') return DEFAULT_METRICS;
    var probe = document.createElement('span');
    probe.style.position = 'absolute';
    probe.style.visibility = 'hidden';
    probe.style.whiteSpace = 'pre';
    probe.style.fontFamily = 'Tessera Mono, monospace';
    probe.style.fontWeight = '400';
    probe.style.fontSize = '16px';
    probe.style.lineHeight = 'normal';
    probe.textContent = 'M'.repeat(32);
    document.body.appendChild(probe);
    var rect = probe.getBoundingClientRect();
    document.body.removeChild(probe);
    var cellWidth = rect.width > 0 ? rect.width / 32 : DEFAULT_METRICS.cellWidth;
    var cellHeight = rect.height > 0 ? rect.height : DEFAULT_METRICS.cellHeight;
    cachedMetrics = { cellWidth: cellWidth, cellHeight: cellHeight, lineHeight: cellHeight, fontFamily: 'Tessera Mono', fontWeight: 400 };
    return cachedMetrics;
  }

  var generation = 0;
  var current = null; // { generation, ws, driver, target }
  var reconnectScheduled = false;

  function scheduleReconnect() {
    if (reconnectScheduled) return;
    reconnectScheduled = true;
    setTimeout(function () {
      reconnectScheduled = false;
      connect();
    }, RECONNECT_BACKOFF_MS);
  }

  // The one and only teardown path: a genuine network drop, a server-initiated post-resync close, and
  // an error-then-close pair all funnel through here via the `close` handler below.
  function teardown(gen) {
    if (!current || current.generation !== gen) return;
    var record = current;
    current = null;
    record.driver.dispose();
    scheduleReconnect();
  }

  function resyncAndClose(gen) {
    if (!current || current.generation !== gen) return;
    sendControlMessage(current.ws, { type: 'resync', id: randomId() });
    current.ws.close();
  }

  function connect() {
    generation += 1;
    var gen = generation;

    var host = document.getElementById('host');
    if (host) host.innerHTML = '';
    var target = new window.Tessera.TesseraHtmlTarget();
    if (host) target.mount(host);
    target.setMetrics(measureMetrics());

    var driver = new window.Tessera.TesseraDriver(target, {
      onProtocolError: function () {
        resyncAndClose(gen);
      },
      onResyncNeeded: function () {
        resyncAndClose(gen);
      },
    });

    var ws = new WebSocket(sessionUrl(tokenFromLocation()));
    current = { generation: gen, ws: ws, driver: driver, target: target };

    ws.onopen = function () {
      if (!current || current.generation !== gen) return;
      sendControlMessage(ws, { type: 'hello', id: randomId(), target: 'html' });
    };

    ws.onmessage = function (event) {
      if (!current || current.generation !== gen) return;
      if (typeof event.data !== 'string') return;
      var parsed;
      try {
        parsed = JSON.parse(event.data);
      } catch (err) {
        return;
      }
      if (!parsed || typeof parsed !== 'object') return;
      if (parsed.schema === WEB_FRAME_SCHEMA) {
        driver.ingest(event.data);
        return;
      }
      if (parsed.schema === CONTROL_SCHEMA && parsed.type === 'error' && typeof console !== 'undefined') {
        console.error('tessera-proxy control error', parsed.id, parsed.message);
      }
      // "ready"/"result" carry nothing this client needs to act on: connection identity is the
      // WebSocket itself, not a server-issued id.
    };

    // Never disposes or reconnects itself -- only closes the still-current socket, which always
    // produces the `close` event that `teardown` actually handles.
    ws.onerror = function () {
      if (!current || current.generation !== gen) return;
      current.ws.close();
    };

    ws.onclose = function () {
      teardown(gen);
    };
  }

  function start() {
    if (typeof document !== 'undefined' && document.fonts && document.fonts.load) {
      document.fonts
        .load('400 16px "Tessera Mono"')
        .catch(function () {})
        .then(function () {
          return document.fonts.ready;
        })
        .catch(function () {})
        .then(connect);
    } else {
      connect();
    }
  }

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', start);
    } else {
      start();
    }
  }
})();
