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
  var CONTROL_VERSION = 2;
  var WEB_FRAME_SCHEMA = 'tessera.web-frame';
  var RECONNECT_BACKOFF_MS = 500;
  var DEFAULT_METRICS = { cellWidth: 9, cellHeight: 18, lineHeight: 18, fontFamily: 'Tessera Mono', fontWeight: 400 };
  // Mirrors lib/model/input_state.ml's own `default`: the modes a session starts in before the
  // application has changed anything. No `tessera.web-frame`/`input_state` message is ever sent until
  // the child has produced its first outcome (lib/proxy_linux/web_server.ml's `note_outcome`), which a
  // perfectly quiet child (nothing printed yet -- no prompt, no output) may never do on its own. Used
  // only for that pre-first-outcome bootstrap window, below.
  var DEFAULT_INPUT_STATE = {
    generation: null,
    application_cursor: false,
    application_keypad: false,
    bracketed_paste: false,
    focus_reporting: false,
    mouse_tracking: 'off',
    mouse_encoding: 'default',
  };

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

  function bytesToBase64(bytes) {
    var binary = '';
    for (var i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return window.btoa(binary);
  }

  function setControlStatus(text) {
    var status = document.getElementById('control-status');
    if (status) status.textContent = text;
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
    record.host.removeEventListener('pointerdown', record.onPointerDown);
    record.host.removeEventListener('pointermove', record.onPointerMove);
    record.host.removeEventListener('pointerup', record.onPointerUp);
    record.host.removeEventListener('keydown', record.onKeyDown);
    record.host.removeEventListener('paste', record.onPaste);
    record.host.removeEventListener('focus', record.onFocus);
    record.host.removeEventListener('blur', record.onBlur);
    record.host.removeEventListener('compositionend', record.onCompositionEnd);
    record.driver.dispose();
    setControlStatus('Read-only terminal mirror');
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
    host.tabIndex = 0;
    var commandKinds = Object.create(null);
    var record = {
      generation: gen,
      ws: ws,
      driver: driver,
      target: target,
      host: host,
      inputCapable: false,
      controller: false,
      acquirePending: false,
      inputState: null,
      geometry: null,
      commandKinds: commandKinds,
      onPointerDown: null,
      onPointerMove: null,
      onPointerUp: null,
      onKeyDown: null,
      onPaste: null,
      onFocus: null,
      onBlur: null,
      onCompositionEnd: null,
    };

    function sendCommand(kind, body) {
      if (!current || current.generation !== gen) return;
      var id = randomId();
      commandKinds[id] = kind;
      sendControlMessage(ws, Object.assign({ type: kind, id: id }, body || {}));
    }

    // Deliberately not gated on `record.inputState.generation === record.displayGeneration`: every
    // input_state a client ever receives (web_publisher.ml's `note_outcome` always enqueues
    // `[input_state; frame]` together for a given generation, in that order; hello/acquire_control-time
    // catch-up sends are likewise always sourced from the same monotonic `last_outcome`) describes a
    // generation that is already-displayed or newer -- never older/stale -- so the freshest input_state
    // received is always safe to encode with, even in the brief window before its matching
    // tessera.web-frame has arrived. Requiring exact equality here used to drop real keystrokes
    // whenever a keydown landed in that window (visible under fast/scripted typing, since each relayed
    // byte the child echoes back can bump the generation).
    function currentInputState() {
      // No authoritative input_state has arrived yet at all -- e.g. control was just acquired on a
      // freshly spawned, still-silent child. Without this, every keystroke is silently dropped forever
      // (encodeKeyboardEvent requires non-null state) and the session can never bootstrap its first
      // outcome, since that requires the child to echo *something* back first.
      return record.inputState || DEFAULT_INPUT_STATE;
    }

    function sendInput(value) {
      if (!record.controller || ws.readyState !== WebSocket.OPEN || !value) return;
      var bytes = value instanceof Uint8Array ? value : new TextEncoder().encode(value);
      if (!bytes.length) return;
      sendCommand('input', { bytes_b64: bytesToBase64(bytes) });
    }

    function pointerGeometry() {
      if (!record.geometry) return null;
      return { columns: record.geometry.columns, rows: record.geometry.rows, rect: host.getBoundingClientRect() };
    }

    function sendPointer(event) {
      var state = currentInputState();
      if (!state) return;
      var input = window.Tessera.ProxyInput.encodePointer(event, state, pointerGeometry());
      if (input !== null) {
        event.preventDefault();
        sendInput(input);
      }
    }

    record.onPointerDown = function (event) {
      if (record.controller) {
        sendPointer(event);
        return;
      }
      if (!record.inputCapable || record.acquirePending) return;
      record.acquirePending = true;
      setControlStatus('Requesting terminal control…');
      sendCommand('acquire_control');
    };
    record.onPointerMove = function (event) {
      if (record.controller) sendPointer(event);
    };
    record.onPointerUp = function (event) {
      if (record.controller) sendPointer(event);
    };
    record.onKeyDown = function (event) {
      if (!record.controller) return;
      var state = currentInputState();
      if (!state) return;
      var text = window.Tessera.ProxyInput.encodeKeyboardEvent(event, state);
      if (text !== null) {
        event.preventDefault();
        sendInput(text);
      }
    };
    record.onPaste = function (event) {
      if (!record.controller) return;
      var text = event.clipboardData && event.clipboardData.getData('text/plain');
      if (text) {
        event.preventDefault();
        sendInput(window.Tessera.ProxyInput.encodePaste(text, currentInputState()));
      }
    };
    record.onFocus = function () { sendInput(window.Tessera.ProxyInput.encodeFocus(true, currentInputState())); };
    record.onBlur = function () { sendInput(window.Tessera.ProxyInput.encodeFocus(false, currentInputState())); };
    record.onCompositionEnd = function (event) {
      if (record.controller && event.data) sendInput(event.data);
    };
    host.addEventListener('pointerdown', record.onPointerDown);
    host.addEventListener('pointermove', record.onPointerMove);
    host.addEventListener('pointerup', record.onPointerUp);
    host.addEventListener('keydown', record.onKeyDown);
    host.addEventListener('paste', record.onPaste);
    host.addEventListener('focus', record.onFocus);
    host.addEventListener('blur', record.onBlur);
    host.addEventListener('compositionend', record.onCompositionEnd);
    current = record;

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
        if (parsed.meta && parsed.meta.geometry) {
          record.geometry = parsed.meta.geometry;
        }
        return;
      }
      if (parsed.schema === CONTROL_SCHEMA && parsed.type === 'ready') {
        record.inputCapable = !!(parsed.capabilities && parsed.capabilities.input);
        setControlStatus(record.inputCapable ? 'Click terminal to request control' : 'Read-only terminal mirror');
        return;
      }
      if (parsed.schema === CONTROL_SCHEMA && parsed.type === 'input_state') {
        record.inputState = parsed.input_state || null;
        return;
      }
      if (parsed.schema === CONTROL_SCHEMA && parsed.type === 'result') {
        var resultKind = commandKinds[parsed.id];
        delete commandKinds[parsed.id];
        if (resultKind === 'acquire_control') {
          record.acquirePending = false;
          record.controller = true;
          host.focus();
          setControlStatus('Web terminal control active');
        } else if (resultKind === 'release_control') {
          record.controller = false;
          setControlStatus('Click terminal to request control');
        }
        return;
      }
      if (parsed.schema === CONTROL_SCHEMA && parsed.type === 'error') {
        var errorKind = commandKinds[parsed.id];
        delete commandKinds[parsed.id];
        if (errorKind === 'acquire_control') {
          record.acquirePending = false;
          setControlStatus('Terminal control unavailable');
        }
        if (typeof console !== 'undefined') console.error('tessera-proxy control error', parsed.id, parsed.message);
      }
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
