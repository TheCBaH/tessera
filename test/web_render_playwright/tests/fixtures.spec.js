// Loads each synthetic fixture from test/web_render_fixtures (test/web_render_playwright/fixtures/
// *.json) directly -- bypassing the bridge/trace machinery entirely -- and asserts DOM placement,
// classes, --tessera-fg/-bg values, accessible text, and document.title after each frame. This is
// what catches DOM/CSS mapping bugs the native projection tests can't, since they never involve
// JavaScript.
//
// The oracle for "does the DOM match the frame" is an independent merge of every ingested frame's own
// decoded structure (see mergeFrames below, evaluated in-page against window.Tessera.decodeHtmlEnvelope),
// not a re-assertion of the driver/target's own internal state -- so this is a real structural check,
// not a tautology.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');

const FIXTURES_DIR = path.join(__dirname, '..', 'fixtures');
const FIXED_METRICS = { cellWidth: 9, cellHeight: 18, lineHeight: 18, fontFamily: 'Tessera Mono', fontWeight: 400 };

const fixtureNames = fs
  .readdirSync(FIXTURES_DIR)
  .filter((f) => f.endsWith('.json'))
  .map((f) => f.replace(/\.json$/, ''))
  .sort();

test.beforeEach(async ({ page }) => {
  // Registered before navigation so it actually takes effect on the goto below.
  await page.addInitScript((metrics) => {
    window.__TESSERA_FIXED_METRICS__ = metrics;
  }, FIXED_METRICS);
  await page.goto('/');
});

// Runs entirely in-page: mounts a fresh TesseraDriver+TesseraHtmlTarget, ingests every frame in the
// named fixture in order, and returns the final probe(), the merged expected structure computed
// independently from the decoded frames, document.title, and (for a two-frame fixture) whether the
// first row's DOM node identity survived the second frame -- untouched rows must never be rebuilt.
async function driveFixture(page, name) {
  return page.evaluate(async (fixtureName) => {
    const res = await fetch('/fixtures/' + fixtureName + '.json');
    const data = await res.json();
    const decodedFrames = data.frames.map((envelope) => {
      const result = window.Tessera.decodeHtmlEnvelope(JSON.stringify(envelope));
      if (!result.ok) throw new Error('fixture decode failed: ' + result.error);
      return result.value;
    });

    const host = document.getElementById('host');
    host.innerHTML = '';
    const target = new window.Tessera.TesseraHtmlTarget();
    target.mount(host);
    target.setMetrics(window.__TESSERA_FIXED_METRICS__);
    const errors = [];
    const driver = new window.Tessera.TesseraDriver(target, {
      onProtocolError: (reason, details) => errors.push(['protocol', reason, details]),
      onResyncNeeded: (reason, details) => errors.push(['resync', reason, details]),
    });

    let firstRowElBeforeLast = null;
    data.frames.forEach((envelope, i) => {
      if (i === data.frames.length - 1 && data.frames.length > 1) {
        firstRowElBeforeLast = target.rowEls.get(0) || null;
      }
      driver.ingest(JSON.stringify(envelope));
    });
    const firstRowElAfterLast = data.frames.length > 1 ? target.rowEls.get(0) || null : null;

    // Independent oracle: merge every decoded frame's own rows/cursor, resetting the row map on a
    // reset frame and overlaying a delta's changed rows on top -- exactly the update rule the wire
    // protocol documents, computed here from the decoded JSON, not from the driver's internal state.
    let rowsByIndex = new Map();
    let cursor = null;
    let columns = null;
    let rowCount = null;
    for (const decoded of decodedFrames) {
      const frame = decoded.frame;
      if (columns === null) {
        columns = frame.columns;
        rowCount = frame.row_count;
      }
      if (decoded.meta.kind === 'reset') rowsByIndex = new Map();
      frame.rows.forEach((r) => rowsByIndex.set(r.index, r));
      cursor = frame.cursor;
    }
    const expectedRows = [];
    for (let i = 0; i < rowCount; i += 1) expectedRows.push(rowsByIndex.get(i));
    const expected = { columns, row_count: rowCount, rows: expectedRows, cursor };

    return {
      probe: target.probe(),
      expected,
      title: document.title,
      lastMetaTitle: decodedFrames[decodedFrames.length - 1].meta.title,
      errors,
      rowIdentityPreserved: data.frames.length > 1 ? firstRowElBeforeLast === firstRowElAfterLast : null,
    };
  }, name);
}

for (const name of fixtureNames) {
  test(`fixture ${name}: DOM matches the merged decoded frame(s), no protocol errors`, async ({ page }) => {
    const result = await driveFixture(page, name);
    expect(result.errors).toEqual([]);
    expect(result.probe).toEqual(result.expected);
  });

  test(`fixture ${name}: document.title reflects the last frame's title when present`, async ({ page }) => {
    const result = await driveFixture(page, name);
    if (result.lastMetaTitle !== null) {
      expect(result.title).toBe(result.lastMetaTitle);
    }
  });
}

// The two dedicated multi-frame cases: prove untouched-row DOM identity survives a second frame that
// does not touch that row (reset-then-delta-row's row 0; delta-cursor-only's only row).
for (const name of ['reset-then-delta-row', 'delta-cursor-only']) {
  test(`fixture ${name}: row 0's DOM node identity is preserved across the second frame`, async ({ page }) => {
    const result = await driveFixture(page, name);
    expect(result.rowIdentityPreserved).toBe(true);
  });
}

test('fixture reset-then-delta-title-only: the delta carries no row or cursor changes', async ({ page }) => {
  const result = await driveFixture(page, 'reset-then-delta-title-only');
  expect(result.errors).toEqual([]);
  expect(result.title).toBe('second title');
});
