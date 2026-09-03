// Driver-only resync/gap unit tests: plain `node --test`, no browser, no Playwright. Proves
// web/tessera-driver.js's rollback-safe *and* recoverable resync state machine against a fake
// `target` object that only records calls, before any DOM/browser code exists. Run first
// (fastest) in `make test-web-render`.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { TesseraDriver } = require(path.join(__dirname, '..', '..', '..', 'web', 'tessera-driver.js'));

function style() {
  return {
    fg: { kind: 'var', name: '--tessera-default-fg' },
    bg: { kind: 'var', name: '--tessera-default-bg' },
    classes: [],
  };
}

function row(index, columns) {
  columns = columns === undefined ? 2 : columns;
  return { index, background: [{ start: 0, width: columns, style: style() }], glyphs: [], text: ' '.repeat(columns) };
}

function envelope({ kind, lineageId, generation, rows, title, geometry, active }) {
  geometry = geometry === undefined ? { columns: 2, rows: 1 } : geometry;
  active = active === undefined ? 'primary' : active;
  const meta = {
    kind,
    active,
    geometry,
    generation: String(generation),
    lineage_id: String(lineageId),
  };
  if (title !== undefined) meta.title = title;
  const frameRows = rows === undefined ? (kind === 'reset' ? [row(0, geometry.columns)] : []) : rows;
  return JSON.stringify({
    schema: 'tessera.web-frame',
    version: 1,
    target: 'html',
    meta,
    frame: {
      columns: geometry.columns,
      row_count: geometry.rows,
      rows: frameRows,
      cursor: { column: 0, row: 0, visible: true, pending_wrap: false, style: style() },
    },
  });
}

function fakeTarget() {
  const calls = [];
  return {
    calls,
    mount(host) {
      calls.push(['mount', host]);
    },
    reset(frame) {
      calls.push(['reset', frame]);
    },
    draw(frame, dirtyRows) {
      calls.push(['draw', frame, dirtyRows]);
    },
    setMetrics(metrics) {
      calls.push(['setMetrics', metrics]);
    },
    dispose() {
      calls.push(['dispose']);
    },
  };
}

function driverWithEvents() {
  const target = fakeTarget();
  const protocolErrors = [];
  const resyncs = [];
  const driver = new TesseraDriver(target, {
    onProtocolError: (reason, details) => protocolErrors.push({ reason, details }),
    onResyncNeeded: (reason, details) => resyncs.push({ reason, details }),
  });
  return { driver, target, protocolErrors, resyncs };
}

test('first frame must be a reset; accepted unconditionally with no prior lineage', () => {
  const { driver, target } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  assert.equal(driver.trackedLineageId, 1n);
  assert.equal(driver.trackedGeneration, 1n);
  assert.equal(driver.awaitingReset, false);
  assert.equal(target.calls.length, 1);
  assert.equal(target.calls[0][0], 'reset');
});

test('sequential deltas apply in order', () => {
  const { driver, target } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 3 }));
  assert.equal(driver.trackedGeneration, 3n);
  assert.deepEqual(
    target.calls.map((c) => c[0]),
    ['reset', 'draw', 'draw']
  );
});

test('duplicate generation is dropped', () => {
  const { driver, target, protocolErrors } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  assert.equal(driver.trackedGeneration, 2n);
  assert.equal(target.calls.length, 2);
  assert.equal(protocolErrors.length, 1);
  assert.equal(protocolErrors[0].reason, 'stale-generation');
});

test('stale generation (reordered delivery) is dropped', () => {
  const { driver, target, protocolErrors } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 3 }));
  // generation 2 is redelivered (reordered/duplicated in transit) after generation 3 is already
  // applied -- it must be dropped, not treated as new content or rolled back into.
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  assert.equal(driver.trackedGeneration, 3n);
  assert.equal(target.calls.length, 3);
  assert.equal(protocolErrors[protocolErrors.length - 1].reason, 'stale-generation');
});

test('a skipped generation is a gap: dropped, awaitingReset set, onResyncNeeded fires', () => {
  const { driver, target, resyncs } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 3 }));
  assert.equal(driver.trackedGeneration, 1n);
  assert.equal(driver.awaitingReset, true);
  assert.equal(target.calls.length, 1);
  assert.equal(resyncs.length, 1);
  assert.equal(resyncs[0].reason, 'generation-gap');
  assert.deepEqual(resyncs[0].details, { expected: '2', got: '3' });
});

test('a delta while awaitingReset is dropped even at a newer generation, resync refires', () => {
  const { driver, target, resyncs } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 3 })); // gap -> awaitingReset
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 4 }));
  assert.equal(driver.awaitingReset, true);
  assert.equal(target.calls.length, 1);
  assert.equal(resyncs[resyncs.length - 1].reason, 'awaiting-reset');
});

test('a delayed/stale same-lineage reset after a newer generation must not roll back', () => {
  const { driver, target, protocolErrors } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 3 }));
  // A stale reset for the same lineage at an older generation arrives late.
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 2 }));
  assert.equal(driver.trackedGeneration, 3n);
  assert.equal(target.calls.length, 3);
  assert.equal(protocolErrors[protocolErrors.length - 1].reason, 'stale-generation');
});

test('a newer same-lineage reset is always applied, even skipping generations', () => {
  const { driver, target } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2 }));
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 10 }));
  assert.equal(driver.trackedGeneration, 10n);
  assert.equal(driver.awaitingReset, false);
  assert.deepEqual(
    target.calls.map((c) => c[0]),
    ['reset', 'draw', 'reset']
  );
});

test('a lineage change carried by a delta is rejected', () => {
  const { driver, target, resyncs } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 2, generation: 1 }));
  assert.equal(driver.trackedLineageId, 1n);
  assert.equal(driver.awaitingReset, true);
  assert.equal(target.calls.length, 1);
  assert.equal(resyncs[resyncs.length - 1].reason, 'lineage-changed-without-reset');
});

test('a lineage change carried by a reset is accepted', () => {
  const { driver, target } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'reset', lineageId: 2, generation: 1 }));
  assert.equal(driver.trackedLineageId, 2n);
  assert.equal(driver.trackedGeneration, 1n);
  assert.equal(driver.awaitingReset, false);
  assert.equal(target.calls.length, 2);
});

test('full recovery: gap forces awaitingReset, a reset under a new lineage id resumes', () => {
  const { driver, target, resyncs } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 12 }));
  assert.equal(driver.trackedGeneration, 12n);
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 14 })); // gap: expected 13
  assert.equal(driver.awaitingReset, true);
  assert.equal(resyncs[resyncs.length - 1].reason, 'generation-gap');
  // Recovery: the recreated bridge gets a new, strictly greater lineage id and restarts at
  // generation 1 -- exactly the shape a real Bridge_runner.create recreation produces.
  driver.ingest(envelope({ kind: 'reset', lineageId: 2, generation: 1 }));
  assert.equal(driver.trackedLineageId, 2n);
  assert.equal(driver.trackedGeneration, 1n);
  assert.equal(driver.awaitingReset, false);
  assert.deepEqual(
    target.calls.map((c) => c[0]),
    ['reset', 'reset']
  );
});

test('recover to a new lineage, then a delayed reset from the retired lineage is dropped, not rolled back', () => {
  const { driver, target, protocolErrors } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 12 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 14 })); // gap
  driver.ingest(envelope({ kind: 'reset', lineageId: 2, generation: 1 })); // recovered
  driver.ingest(envelope({ kind: 'delta', lineageId: 2, generation: 2 }));
  const callsBefore = target.calls.length;
  // A delayed reset from the retired lineage 1 arrives after recovery.
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 99 }));
  assert.equal(driver.trackedLineageId, 2n);
  assert.equal(driver.trackedGeneration, 2n);
  assert.equal(target.calls.length, callsBefore);
  assert.equal(protocolErrors[protocolErrors.length - 1].reason, 'stale-lineage');
  assert.deepEqual(protocolErrors[protocolErrors.length - 1].details, { tracked: '2', got: '1' });
});

test('a delta claiming a changed geometry is rejected, not drawn onto the old grid', () => {
  const { driver, target, resyncs } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1, geometry: { columns: 2, rows: 1 } }));
  driver.ingest(
    envelope({ kind: 'delta', lineageId: 1, generation: 2, geometry: { columns: 3, rows: 2 }, rows: [] })
  );
  assert.equal(driver.trackedGeneration, 1n);
  assert.deepEqual(driver.trackedGeometry, { columns: 2, rows: 1 });
  assert.equal(driver.awaitingReset, true);
  assert.equal(target.calls.length, 1);
  assert.equal(resyncs[resyncs.length - 1].reason, 'geometry-changed-without-reset');
  assert.deepEqual(resyncs[resyncs.length - 1].details, {
    tracked: { columns: 2, rows: 1 },
    got: { columns: 3, rows: 2 },
  });
});

test('a delta claiming an active-screen change is rejected, not drawn onto the old screen', () => {
  const { driver, target, resyncs } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1, active: 'primary' }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2, active: 'alternate', rows: [] }));
  assert.equal(driver.trackedGeneration, 1n);
  assert.equal(driver.trackedActive, 'primary');
  assert.equal(driver.awaitingReset, true);
  assert.equal(target.calls.length, 1);
  assert.equal(resyncs[resyncs.length - 1].reason, 'active-changed-without-reset');
  assert.deepEqual(resyncs[resyncs.length - 1].details, { tracked: 'primary', got: 'alternate' });
});

test('a reset legitimately changing geometry and active screen updates tracked state', () => {
  const { driver, target } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1, geometry: { columns: 2, rows: 1 } }));
  driver.ingest(
    envelope({
      kind: 'reset',
      lineageId: 1,
      generation: 2,
      geometry: { columns: 3, rows: 2 },
      active: 'alternate',
      rows: [row(0, 3), row(1, 3)],
    })
  );
  assert.deepEqual(driver.trackedGeometry, { columns: 3, rows: 2 });
  assert.equal(driver.trackedActive, 'alternate');
  assert.equal(driver.awaitingReset, false);
  // A subsequent delta at the new geometry/active screen is accepted normally.
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 3, geometry: { columns: 3, rows: 2 }, active: 'alternate', rows: [] }));
  assert.equal(driver.trackedGeneration, 3n);
  assert.deepEqual(
    target.calls.map((c) => c[0]),
    ['reset', 'reset', 'draw']
  );
});

test('a decode failure forces awaitingReset and reports onProtocolError', () => {
  const { driver, target, protocolErrors } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest('{"not":"a valid envelope"}');
  assert.equal(driver.awaitingReset, true);
  assert.equal(target.calls.length, 1);
  assert.equal(protocolErrors[protocolErrors.length - 1].reason, 'decode-failed');
});

test('cursor-only delta carries no row changes and reports an empty dirtyRows list', () => {
  const { driver, target } = driverWithEvents();
  driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1 }));
  driver.ingest(envelope({ kind: 'delta', lineageId: 1, generation: 2, rows: [] }));
  const drawCall = target.calls[1];
  assert.equal(drawCall[0], 'draw');
  assert.deepEqual(drawCall[2], []);
});

test('document.title is untouched (and does not throw) outside a browser', () => {
  assert.equal(typeof document, 'undefined');
  const { driver } = driverWithEvents();
  assert.doesNotThrow(() => {
    driver.ingest(envelope({ kind: 'reset', lineageId: 1, generation: 1, title: 'hello' }));
  });
});
