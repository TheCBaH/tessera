// The JS-side trust boundary for tessera.web-frame envelopes: JavaScript performs only the browser
// operations OCaml cannot perform. Pure functions,
// no DOM, no globals beyond exporting themselves -- independently unit-tested under plain Node (see
// test/web_render_playwright/tests/driver.node.test.js and the dedicated decode tests) with no
// browser required.
//
// decodeHtmlEnvelope mirrors, rather than solely implements, the exact structural contract
// lib/web_rendering/web_json.ml's `html_envelope_jsont`/`meta_jsont` already enforce on the OCaml
// side: schema/version/target constants; meta.geometry positive and agreeing with frame.columns/
// row_count; row indices unique and in range; every background/glyph span fitting its row; a row's
// backgrounds exactly tiling it (no gaps, no overlaps); glyphs on a row pairwise non-overlapping (in
// wire order -- see below); a `reset` carrying exactly row_count rows; the cursor in bounds; and
// `meta.generation`/`meta.lineage_id` matching the canonical non-negative decimal syntax
// `^(0|[1-9][0-9]*)$` that lib/web_rendering/web_json.ml's `canonical_decimal` now enforces on the
// OCaml codec itself -- this function mirrors an OCaml-enforced rule, it does not stand as that
// rule's only enforcement. Every fg/bg/class is
// checked against the same closed set Web_html.valid_color_value/valid_class accept, duplicated here
// deliberately: a payload reaching this decoder in a future transport may not come from a trusted
// same-process OCaml call.
//
// Background/glyph tiling walks spans in the order the wire array gives them (matching
// lib/web_rendering/web_json.ml's `background_tiles`/`glyphs_ok`, which walk their input list without
// sorting first): a structurally valid row's spans are already emitted in increasing-start order by
// `Web_html.of_frame`, and a payload whose spans are merely out of order is rejected here exactly as
// it would be rejected natively, not silently reordered into acceptance.

(function (root, factory) {
  var exported = factory();
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = exported;
  }
  var globalObj = typeof globalThis !== 'undefined' ? globalThis : root;
  globalObj.Tessera = Object.assign(globalObj.Tessera || {}, exported);
})(this, function () {
  'use strict';

  var SCHEMA = 'tessera.web-frame';
  var VERSION = 1;
  var TARGET = 'html';

  var VALID_CLASSES = {
    'tessera-bold': true,
    'tessera-faint': true,
    'tessera-invisible': true,
    'tessera-inverse': true,
    'tessera-italic': true,
    'tessera-strikethrough': true,
    'tessera-underline': true,
  };

  var DECIMAL_RE = /^(0|[1-9][0-9]*)$/;
  var HEX_RE = /^#[0-9a-f]{6}$/;
  var COLOR_INDEX_RE = /^[0-9]+$/;

  function err(message) {
    return { ok: false, error: message };
  }

  function isPlainObject(v) {
    return typeof v === 'object' && v !== null && !Array.isArray(v);
  }

  function isNonNegativeInt(v) {
    return typeof v === 'number' && Number.isInteger(v) && v >= 0;
  }

  // Given start >= 0 (checked by callers before this runs), start <= columns guarantees
  // columns - start cannot be negative, so the width check cannot be fooled by wraparound the way a
  // naive start + width <= columns computation could be -- mirrors
  // lib/web_rendering/web_json.ml's `fits_within` exactly.
  function fitsWithin(start, width, columns) {
    return (
      isNonNegativeInt(start) && typeof width === 'number' && Number.isInteger(width) && width >= 1 &&
      start <= columns && width <= columns - start
    );
  }

  function validColorValue(cv) {
    if (!isPlainObject(cv)) return false;
    if (cv.kind === 'var') {
      if (typeof cv.name !== 'string') return false;
      if (cv.name === '--tessera-default-fg' || cv.name === '--tessera-default-bg') return true;
      var prefix = '--tessera-color-';
      if (cv.name.slice(0, prefix.length) !== prefix) return false;
      var digits = cv.name.slice(prefix.length);
      if (digits.length === 0 || !COLOR_INDEX_RE.test(digits)) return false;
      var n = Number(digits);
      return Number.isInteger(n) && n >= 0 && n <= 255;
    }
    if (cv.kind === 'hex') {
      return typeof cv.value === 'string' && HEX_RE.test(cv.value);
    }
    return false;
  }

  function validStyle(style) {
    if (!isPlainObject(style)) return false;
    if (!validColorValue(style.fg) || !validColorValue(style.bg)) return false;
    if (!Array.isArray(style.classes)) return false;
    for (var i = 0; i < style.classes.length; i += 1) {
      var c = style.classes[i];
      if (typeof c !== 'string' || !VALID_CLASSES[c]) return false;
    }
    return true;
  }

  function backgroundTiles(background, columns) {
    if (!Array.isArray(background) || background.length === 0) return false;
    var expect = 0;
    for (var i = 0; i < background.length; i += 1) {
      var span = background[i];
      if (!isPlainObject(span)) return false;
      if (!validStyle(span.style)) return false;
      if (!fitsWithin(span.start, span.width, columns)) return false;
      if (span.start !== expect) return false;
      expect = span.start + span.width;
    }
    return expect === columns;
  }

  function glyphsOk(glyphs, columns) {
    if (!Array.isArray(glyphs)) return false;
    var cursor = 0;
    for (var i = 0; i < glyphs.length; i += 1) {
      var g = glyphs[i];
      if (!isPlainObject(g)) return false;
      if (typeof g.text !== 'string') return false;
      if (!validStyle(g.style)) return false;
      if (!fitsWithin(g.start, g.width, columns)) return false;
      if (g.start < cursor) return false;
      cursor = g.start + g.width;
    }
    return true;
  }

  function decodeHtmlFrame(frame, geometry) {
    if (!isPlainObject(frame)) return null;
    var columns = frame.columns;
    var rowCount = frame.row_count;
    var rows = frame.rows;
    var cursor = frame.cursor;
    if (!isNonNegativeInt(columns) || columns < 1) return null;
    if (!isNonNegativeInt(rowCount) || rowCount < 1) return null;
    if (columns !== geometry.columns || rowCount !== geometry.rows) return null;
    if (!Array.isArray(rows)) return null;
    for (var i = 0; i < rows.length; i += 1) {
      var r = rows[i];
      if (!isPlainObject(r)) return null;
      if (!isNonNegativeInt(r.index)) return null;
      if (typeof r.text !== 'string') return null;
      if (!backgroundTiles(r.background, columns)) return null;
      if (!glyphsOk(r.glyphs, columns)) return null;
    }
    // Sorted only for the uniqueness/range check itself -- mirrors
    // lib/web_rendering/web_json.ml's `unique_and_in_range`, scaling with the number of row objects
    // actually present rather than an attacker-controlled `row_count`.
    var indices = rows.map(function (r) {
      return r.index;
    });
    indices.sort(function (a, b) {
      return a - b;
    });
    for (var j = 0; j < indices.length; j += 1) {
      if (indices[j] >= rowCount) return null;
      if (j > 0 && indices[j] === indices[j - 1]) return null;
    }
    if (!isPlainObject(cursor)) return null;
    if (!isNonNegativeInt(cursor.column) || cursor.column >= columns) return null;
    if (!isNonNegativeInt(cursor.row) || cursor.row >= rowCount) return null;
    if (typeof cursor.visible !== 'boolean') return null;
    if (typeof cursor.pending_wrap !== 'boolean') return null;
    if (!validStyle(cursor.style)) return null;
    return { columns: columns, row_count: rowCount, rows: rows, cursor: cursor };
  }

  function decodeHtmlEnvelope(json) {
    var parsed;
    try {
      parsed = JSON.parse(json);
    } catch (e) {
      return err('malformed JSON: ' + e.message);
    }
    if (!isPlainObject(parsed)) return err('envelope is not an object');
    if (parsed.schema !== SCHEMA || parsed.version !== VERSION || parsed.target !== TARGET) {
      return err('html envelope schema/version/target');
    }
    var meta = parsed.meta;
    if (!isPlainObject(meta)) return err('missing meta');
    if (meta.kind !== 'reset' && meta.kind !== 'delta') return err('invalid frame kind');
    if (meta.active !== 'primary' && meta.active !== 'alternate') return err('invalid screen');
    var geometry = meta.geometry;
    if (
      !isPlainObject(geometry) ||
      !isNonNegativeInt(geometry.columns) ||
      geometry.columns < 1 ||
      !isNonNegativeInt(geometry.rows) ||
      geometry.rows < 1
    ) {
      return err('invalid geometry');
    }
    if (typeof meta.generation !== 'string' || !DECIMAL_RE.test(meta.generation)) {
      return err('generation must be a canonical non-negative decimal integer');
    }
    if (typeof meta.lineage_id !== 'string' || !DECIMAL_RE.test(meta.lineage_id)) {
      return err('lineage_id must be a canonical non-negative decimal integer');
    }
    if (meta.title !== undefined && meta.title !== null && typeof meta.title !== 'string') {
      return err('invalid title');
    }
    var frame = decodeHtmlFrame(parsed.frame, geometry);
    if (frame === null) return err('invalid html frame geometry');
    if (meta.kind === 'reset' && frame.rows.length !== frame.row_count) return err('incomplete html reset');
    return {
      ok: true,
      value: {
        schema: parsed.schema,
        version: parsed.version,
        target: parsed.target,
        meta: {
          kind: meta.kind,
          active: meta.active,
          geometry: geometry,
          generation: meta.generation,
          lineage_id: meta.lineage_id,
          title: meta.title === undefined ? null : meta.title,
        },
        frame: frame,
      },
    };
  }

  return {
    decodeHtmlEnvelope: decodeHtmlEnvelope,
    validColorValue: validColorValue,
    validStyle: validStyle,
  };
});
