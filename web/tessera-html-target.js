// The HTML TerminalTarget: builds DOM
// nodes from Web_html.t's structured frame data via createElement/className/style.setProperty/
// textContent only -- never innerHTML, so no HTML-escaping logic is needed here at all (every
// position/color/class was already fully decided by OCaml and validated by tessera-decode.js before
// this module ever sees it).
//
// Row/span/cursor construction matches lib/web_rendering/web_html.ml's `add_row`/`add_background`/
// `add_glyph`/`add_cursor` exactly: the same classes (`tessera-row`/`tessera-bg`/`tessera-glyph`/
// `tessera-cursor`/`tessera-sr-only`), the same `data-*` attributes (`data-start`/`data-width`,
// `data-column`/`data-row`/`data-visible`/`data-pending-wrap`), and the same CSS custom-property-based
// colors (`--tessera-fg`/`--tessera-bg`, `var(--tessera-...)` or a literal `#rrggbb`) and explicit
// grid placement (`grid-column`/`grid-row`) -- just built as DOM nodes instead of a markup string.
//
// `probe()` is test-only (never used by `ingest`/`reset`/`draw` themselves): it reconstructs
// {columns, row_count, rows, cursor} by reading back `data-*`, the `--tessera-fg`/`--tessera-bg`
// inline custom-property values, `classList`, and `textContent` from the live DOM, for Playwright
// structural assertions -- a target-specific structural probe.

(function (root, factory) {
  var exported = factory();
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = exported;
  }
  var globalObj = typeof globalThis !== 'undefined' ? globalThis : root;
  globalObj.Tessera = Object.assign(globalObj.Tessera || {}, exported);
})(this, function () {
  'use strict';

  var REQUIRED_METRICS = ['cellWidth', 'cellHeight', 'lineHeight', 'fontFamily', 'fontWeight'];

  function cssValueOf(colorValue) {
    return colorValue.kind === 'var' ? 'var(' + colorValue.name + ')' : colorValue.value;
  }

  function applyColorStyle(el, style) {
    el.style.setProperty('--tessera-fg', cssValueOf(style.fg));
    el.style.setProperty('--tessera-bg', cssValueOf(style.bg));
  }

  function classAttr(base, style) {
    return [base].concat(style.classes).join(' ');
  }

  // CSS grid lines are 1-indexed, mirroring lib/web_rendering/web_html.ml's `grid_column` exactly.
  function gridColumnSpan(start, width) {
    return start + 1 + ' / span ' + width;
  }

  function buildBackground(doc, span) {
    var el = doc.createElement('span');
    el.className = classAttr('tessera-bg', span.style);
    applyColorStyle(el, span.style);
    el.style.setProperty('grid-column', gridColumnSpan(span.start, span.width));
    el.dataset.start = String(span.start);
    el.dataset.width = String(span.width);
    return el;
  }

  function buildGlyph(doc, glyph) {
    var el = doc.createElement('span');
    el.className = classAttr('tessera-glyph', glyph.style);
    applyColorStyle(el, glyph.style);
    el.style.setProperty('grid-column', gridColumnSpan(glyph.start, glyph.width));
    el.dataset.start = String(glyph.start);
    el.dataset.width = String(glyph.width);
    el.textContent = glyph.text;
    return el;
  }

  function buildRow(doc, row) {
    var el = doc.createElement('div');
    el.className = 'tessera-row';
    el.style.setProperty('grid-row', String(row.index + 1));
    el.dataset.row = String(row.index);
    row.background.forEach(function (span) {
      el.appendChild(buildBackground(doc, span));
    });
    row.glyphs.forEach(function (glyph) {
      el.appendChild(buildGlyph(doc, glyph));
    });
    var sr = doc.createElement('span');
    sr.className = 'tessera-sr-only';
    sr.textContent = row.text;
    el.appendChild(sr);
    return el;
  }

  function buildCursor(doc, cursor) {
    var el = doc.createElement('div');
    el.className = classAttr('tessera-cursor', cursor.style);
    applyColorStyle(el, cursor.style);
    el.style.setProperty('grid-column', String(cursor.column + 1));
    el.style.setProperty('grid-row', String(cursor.row + 1));
    el.dataset.column = String(cursor.column);
    el.dataset.row = String(cursor.row);
    el.dataset.visible = String(cursor.visible);
    el.dataset.pendingWrap = String(cursor.pending_wrap);
    return el;
  }

  function colorValueFromCssValue(raw) {
    var value = (raw || '').trim();
    var varMatch = /^var\((--[a-zA-Z0-9-]+)\)$/.exec(value);
    if (varMatch) return { kind: 'var', name: varMatch[1] };
    return { kind: 'hex', value: value };
  }

  function styleFromElement(el, baseClass) {
    var classes = [];
    el.classList.forEach(function (c) {
      if (c !== baseClass) classes.push(c);
    });
    return {
      fg: colorValueFromCssValue(el.style.getPropertyValue('--tessera-fg')),
      bg: colorValueFromCssValue(el.style.getPropertyValue('--tessera-bg')),
      classes: classes,
    };
  }

  function TesseraHtmlTarget() {
    this.host = null;
    this.frameEl = null;
    this.rowEls = new Map();
    this.cursorEl = null;
    this.columns = 0;
    this.rowCount = 0;
  }

  TesseraHtmlTarget.prototype.mount = function (host) {
    this.host = host;
    var doc = host.ownerDocument || document;
    this.frameEl = doc.createElement('div');
    this.frameEl.className = 'tessera-frame';
    host.appendChild(this.frameEl);
  };

  TesseraHtmlTarget.prototype.setMetrics = function (metrics) {
    for (var i = 0; i < REQUIRED_METRICS.length; i += 1) {
      var key = REQUIRED_METRICS[i];
      if (metrics[key] === undefined || metrics[key] === null) {
        throw new Error('TesseraHtmlTarget.setMetrics: missing required "' + key + '"');
      }
    }
    // cellWidth/cellHeight/lineHeight feed directly into grid-template-columns/-rows (via
    // tessera.css's `var(--tessera-cell-width, 1ch)`/`var(--tessera-line-height, 1.2em)`), which
    // requires a CSS <length> -- a bare unitless number there is invalid and silently collapses the
    // whole grid track list to nothing (caught by a real screenshot test: the DOM structure alone
    // looked correct, but the element rendered at 0x0). Pixel values are appended here, once, so
    // every caller supplies a plain number.
    this.frameEl.style.setProperty('--tessera-cell-width', metrics.cellWidth + 'px');
    this.frameEl.style.setProperty('--tessera-cell-height', metrics.cellHeight + 'px');
    this.frameEl.style.setProperty('--tessera-line-height', metrics.lineHeight + 'px');
    this.frameEl.style.setProperty('--tessera-font-family', metrics.fontFamily);
    this.frameEl.style.setProperty('--tessera-font-weight', String(metrics.fontWeight));
  };

  TesseraHtmlTarget.prototype.reset = function (frame) {
    var doc = this.frameEl.ownerDocument;
    this.columns = frame.columns;
    this.rowCount = frame.row_count;
    this.frameEl.style.setProperty('--tessera-columns', String(frame.columns));
    this.frameEl.style.setProperty('--tessera-rows', String(frame.row_count));
    // Clear every tracked row, including any DOM row node left over from a larger prior geometry
    // whose index is now >= the new row_count (explicit shrink cleanup).
    this.rowEls.forEach(function (el) {
      if (el.parentNode) el.parentNode.removeChild(el);
    });
    this.rowEls.clear();
    if (this.cursorEl && this.cursorEl.parentNode) this.cursorEl.parentNode.removeChild(this.cursorEl);
    this.cursorEl = null;
    var byIndex = new Map();
    frame.rows.forEach(function (row) {
      byIndex.set(row.index, row);
    });
    for (var index = 0; index < frame.row_count; index += 1) {
      var el = buildRow(doc, byIndex.get(index));
      this.frameEl.appendChild(el);
      this.rowEls.set(index, el);
    }
    this.cursorEl = buildCursor(doc, frame.cursor);
    this.frameEl.appendChild(this.cursorEl);
  };

  TesseraHtmlTarget.prototype.draw = function (frame, dirtyRows) {
    var doc = this.frameEl.ownerDocument;
    var self = this;
    var byIndex = new Map();
    frame.rows.forEach(function (row) {
      byIndex.set(row.index, row);
    });
    dirtyRows.forEach(function (index) {
      var row = byIndex.get(index);
      if (row === undefined) return;
      var newEl = buildRow(doc, row);
      var oldEl = self.rowEls.get(index);
      if (oldEl && oldEl.parentNode) oldEl.parentNode.replaceChild(newEl, oldEl);
      else self.frameEl.appendChild(newEl);
      self.rowEls.set(index, newEl);
    });
    var newCursor = buildCursor(doc, frame.cursor);
    if (this.cursorEl && this.cursorEl.parentNode) this.cursorEl.parentNode.replaceChild(newCursor, this.cursorEl);
    else this.frameEl.appendChild(newCursor);
    this.cursorEl = newCursor;
  };

  TesseraHtmlTarget.prototype.dispose = function () {
    if (this.frameEl && this.frameEl.parentNode) this.frameEl.parentNode.removeChild(this.frameEl);
    this.frameEl = null;
    this.host = null;
    this.rowEls.clear();
    this.cursorEl = null;
  };

  // Test-only: not part of the production TerminalTarget interface. Reconstructs the frame the live
  // DOM currently represents, for structural Playwright assertions independent of a screenshot.
  TesseraHtmlTarget.prototype.probe = function () {
    var rows = [];
    for (var i = 0; i < this.rowCount; i += 1) {
      var rowEl = this.rowEls.get(i);
      if (!rowEl) continue;
      var background = [];
      rowEl.querySelectorAll(':scope > .tessera-bg').forEach(function (el) {
        background.push({
          start: Number(el.dataset.start),
          width: Number(el.dataset.width),
          style: styleFromElement(el, 'tessera-bg'),
        });
      });
      var glyphs = [];
      rowEl.querySelectorAll(':scope > .tessera-glyph').forEach(function (el) {
        glyphs.push({
          start: Number(el.dataset.start),
          width: Number(el.dataset.width),
          text: el.textContent,
          style: styleFromElement(el, 'tessera-glyph'),
        });
      });
      var srEl = rowEl.querySelector(':scope > .tessera-sr-only');
      rows.push({ index: i, background: background, glyphs: glyphs, text: srEl ? srEl.textContent : '' });
    }
    var cursor = null;
    if (this.cursorEl) {
      cursor = {
        column: Number(this.cursorEl.dataset.column),
        row: Number(this.cursorEl.dataset.row),
        visible: this.cursorEl.dataset.visible === 'true',
        pending_wrap: this.cursorEl.dataset.pendingWrap === 'true',
        style: styleFromElement(this.cursorEl, 'tessera-cursor'),
      };
    }
    return { columns: this.columns, row_count: this.rowCount, rows: rows, cursor: cursor };
  };

  return { TesseraHtmlTarget: TesseraHtmlTarget };
});
