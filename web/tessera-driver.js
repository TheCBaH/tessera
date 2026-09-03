// The rollback-safe *and* recoverable resync state machine for tessera.web-frame envelopes. No
// DOM/terminal logic lives here: this module only decodes each frame via Tessera.decodeHtmlEnvelope
// (see tessera-decode.js) and dispatches accepted frames to a `target` implementing
// mount/reset/draw/setMetrics/dispose (the TerminalTarget interface). That makes the
// resync logic itself testable under plain Node with a fake recording target -- see
// test/web_render_playwright/tests/driver.node.test.js -- with no browser and no real DOM target
// required.
//
// Tracking state is `{lineageId, generation, awaitingReset}`, starting with no lineage/generation and
// `awaitingReset = true`. Both `lineageId`/`generation` are tracked as BigInt (never JS `number`,
// which cannot represent every value `Tessera_foundation.UInt.t` can) -- safe because
// tessera-decode.js has already proven both fields match the canonical decimal syntax
// `^(0|[1-9][0-9]*)$` before this module ever calls `BigInt` on them.
//
// Resync rules:
//  - no lineage tracked yet: the frame must be a reset, applied unconditionally.
//  - a lineage <= the tracked one: dropped unconditionally (a delayed frame from a retired/stale
//    lineage), reported via onProtocolError('stale-lineage', ...) -- never applied, regardless of
//    kind. A well-behaved host never actually produces this; it is a defensive drop.
//  - a lineage > the tracked one: a genuine newer lineage. The frame must be a reset, applied
//    unconditionally with respect to generation (a new lineage's generation counter restarts
//    independently). A non-reset frame here is dropped, awaitingReset is (re)set, and
//    onResyncNeeded('lineage-changed-without-reset') fires.
//  - same lineage, generation <= tracked: dropped unconditionally, including a stale reset (a newer
//    reset must never be rolled back by an older one that arrives late).
//  - same lineage, kind: reset, generation > tracked: always applied (a newer reset is a valid,
//    authoritative full replacement even if it skips generations).
//  - same lineage, kind: delta, generation > tracked: dropped with onResyncNeeded('awaiting-reset')
//    while awaitingReset is set (only a reset ends that state); otherwise, when generation is exactly
//    trackedGeneration + 1, its meta.geometry/meta.active are checked against what the last accepted
//    reset established -- Web_frame.of_outcome deliberately upgrades both a resize and an
//    active-screen transition to a reset (lib/web_rendering/web_frame.ml), so a delta claiming either
//    one changed is itself a protocol violation, not a smaller update to apply. A mismatch is dropped
//    with onResyncNeeded('geometry-changed-without-reset', {tracked, got}) or
//    onResyncNeeded('active-changed-without-reset', {tracked, got}) and awaitingReset set to true,
//    exactly like a lineage change without a reset. Otherwise the delta is applied via target.draw.
//    A generation that skips ahead is dropped with onResyncNeeded('generation-gap', {expected, got})
//    and awaitingReset set to true -- the driver never self-heals by repainting a partial delta. The
//    only supported recovery from onResyncNeeded is a reset under a new, strictly greater lineage id;
//    there is no in-band "resend generation N" request in this protocol.
//
// document.title is set from meta.title (never silently dropped) on every accepted reset/draw, but
// only when `document` actually exists: this driver is deliberately usable outside a browser (the
// Node-only resync unit tests construct one against a fake target), so touching a browser global is
// guarded rather than assumed.

(function (root, factory) {
  var Tessera = typeof module !== 'undefined' && module.exports ? require('./tessera-decode.js') : root.Tessera;
  var exported = factory(Tessera);
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = exported;
  }
  var globalObj = typeof globalThis !== 'undefined' ? globalThis : root;
  globalObj.Tessera = Object.assign(globalObj.Tessera || {}, exported);
})(this, function (Tessera) {
  'use strict';

  function noop() {}

  function TesseraDriver(target, options) {
    options = options || {};
    this.target = target;
    this.trackedLineageId = null;
    this.trackedGeneration = null;
    this.trackedGeometry = null;
    this.trackedActive = null;
    this.awaitingReset = true;
    this.onProtocolError = options.onProtocolError || noop;
    this.onResyncNeeded = options.onResyncNeeded || noop;
  }

  TesseraDriver.prototype.mount = function (host) {
    this.target.mount(host);
  };

  TesseraDriver.prototype.setMetrics = function (metrics) {
    this.target.setMetrics(metrics);
  };

  TesseraDriver.prototype.dispose = function () {
    this.target.dispose();
  };

  TesseraDriver.prototype._applyTitle = function (meta) {
    if (typeof document !== 'undefined' && meta.title !== null && meta.title !== undefined) {
      document.title = meta.title;
    }
  };

  TesseraDriver.prototype._applyReset = function (lineageId, generation, meta, frame) {
    this.trackedLineageId = lineageId;
    this.trackedGeneration = generation;
    this.trackedGeometry = meta.geometry;
    this.trackedActive = meta.active;
    this.awaitingReset = false;
    this.target.reset(frame);
    this._applyTitle(meta);
  };

  TesseraDriver.prototype._applyDelta = function (generation, meta, frame) {
    this.trackedGeneration = generation;
    var dirtyRows = frame.rows.map(function (row) {
      return row.index;
    });
    this.target.draw(frame, dirtyRows);
    this._applyTitle(meta);
  };

  TesseraDriver.prototype.ingest = function (jsonText) {
    var decoded = Tessera.decodeHtmlEnvelope(jsonText);
    if (!decoded.ok) {
      this.awaitingReset = true;
      this.onProtocolError('decode-failed', { error: decoded.error });
      return;
    }
    var value = decoded.value;
    var meta = value.meta;
    var frame = value.frame;
    var lineageId = BigInt(meta.lineage_id);
    var generation = BigInt(meta.generation);

    if (this.trackedLineageId === null) {
      if (meta.kind !== 'reset') {
        this.awaitingReset = true;
        this.onResyncNeeded('lineage-changed-without-reset');
        return;
      }
      this._applyReset(lineageId, generation, meta, frame);
      return;
    }

    if (lineageId !== this.trackedLineageId) {
      if (lineageId <= this.trackedLineageId) {
        this.onProtocolError('stale-lineage', {
          tracked: this.trackedLineageId.toString(),
          got: lineageId.toString(),
        });
        return;
      }
      if (meta.kind !== 'reset') {
        this.awaitingReset = true;
        this.onResyncNeeded('lineage-changed-without-reset');
        return;
      }
      this._applyReset(lineageId, generation, meta, frame);
      return;
    }

    // Same lineage, any frame kind: a generation no newer than what's already applied is stale or
    // duplicate -- including a stale reset, which must not roll the target backward.
    if (generation <= this.trackedGeneration) {
      this.onProtocolError('stale-generation', {
        tracked: this.trackedGeneration.toString(),
        got: generation.toString(),
      });
      return;
    }

    if (meta.kind === 'reset') {
      this._applyReset(lineageId, generation, meta, frame);
      return;
    }

    if (this.awaitingReset) {
      this.onResyncNeeded('awaiting-reset');
      return;
    }

    var expected = this.trackedGeneration + 1n;
    if (generation === expected) {
      if (meta.geometry.columns !== this.trackedGeometry.columns || meta.geometry.rows !== this.trackedGeometry.rows) {
        this.awaitingReset = true;
        this.onResyncNeeded('geometry-changed-without-reset', {
          tracked: this.trackedGeometry,
          got: meta.geometry,
        });
        return;
      }
      if (meta.active !== this.trackedActive) {
        this.awaitingReset = true;
        this.onResyncNeeded('active-changed-without-reset', {
          tracked: this.trackedActive,
          got: meta.active,
        });
        return;
      }
      this._applyDelta(generation, meta, frame);
      return;
    }

    this.awaitingReset = true;
    this.onResyncNeeded('generation-gap', { expected: expected.toString(), got: generation.toString() });
  };

  return { TesseraDriver: TesseraDriver };
});
