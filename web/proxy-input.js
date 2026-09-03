// Pure browser-event encoder for tessera.proxy-web protocol v2.  The proxy only accepts raw input
// bytes: terminal-mode interpretation lives here and is driven exclusively by `state`, which the
// caller (proxy-web.js) derives from the most recent authoritative input_state message it has
// received -- or a conservative all-off default before the first one ever arrives.
(function (global) {
  'use strict';

  var ESC = '\x1b';

  function controlCharacter(key) {
    if (key.length !== 1) return null;
    var code = key.toUpperCase().charCodeAt(0);
    return code >= 64 && code <= 95 ? String.fromCharCode(code & 0x1f) : null;
  }

  function modifierCode(event) {
    var value = 1;
    if (event.shiftKey) value += 1;
    if (event.altKey) value += 2;
    if (event.ctrlKey) value += 4;
    return value;
  }

  function cursorKey(final, event, state) {
    var prefix = state.application_cursor ? ESC + 'O' : ESC + '[';
    var modifier = modifierCode(event);
    return modifier === 1 ? prefix + final : ESC + '[' + '1;' + modifier + final;
  }

  function keypadKey(code, state) {
    if (!state.application_keypad) return null;
    var suffix = {
      Numpad0: 'p', Numpad1: 'q', Numpad2: 'r', Numpad3: 's', Numpad4: 't',
      Numpad5: 'u', Numpad6: 'v', Numpad7: 'w', Numpad8: 'x', Numpad9: 'y',
      NumpadDecimal: 'n', NumpadDivide: 'o', NumpadMultiply: 'j', NumpadSubtract: 'm',
      NumpadAdd: 'k', NumpadEnter: 'M',
    }[code];
    return suffix ? ESC + 'O' + suffix : null;
  }

  function encodeKeyboardEvent(event, state) {
    if (!state || event.isComposing || event.key === 'Dead' || event.key === 'Process') return null;
    var keypad = keypadKey(event.code, state);
    if (keypad) return keypad;
    var cursor = { ArrowUp: 'A', ArrowDown: 'B', ArrowRight: 'C', ArrowLeft: 'D' }[event.key];
    if (cursor) return cursorKey(cursor, event, state);
    var special = {
      Enter: '\r', Backspace: '\x7f', Tab: '\t', Escape: ESC,
      Home: ESC + '[H', End: ESC + '[F', Insert: ESC + '[2~', Delete: ESC + '[3~',
      PageUp: ESC + '[5~', PageDown: ESC + '[6~', F1: ESC + 'OP', F2: ESC + 'OQ',
      F3: ESC + 'OR', F4: ESC + 'OS', F5: ESC + '[15~', F6: ESC + '[17~',
      F7: ESC + '[18~', F8: ESC + '[19~', F9: ESC + '[20~', F10: ESC + '[21~',
      F11: ESC + '[23~', F12: ESC + '[24~',
    }[event.key];
    if (special) return special;
    if (event.ctrlKey && !event.altKey && !event.metaKey) return controlCharacter(event.key);
    if (!event.ctrlKey && !event.altKey && !event.metaKey && event.key.length === 1) return event.key;
    return null;
  }

  function encodePaste(text, state) {
    if (!text) return null;
    return state && state.bracketed_paste ? ESC + '[200~' + text + ESC + '[201~' : text;
  }

  function encodeFocus(focused, state) {
    return state && state.focus_reporting ? ESC + (focused ? '[I' : '[O') : null;
  }

  function pointerCell(event, geometry) {
    if (!geometry || !geometry.rect || geometry.columns < 1 || geometry.rows < 1) return null;
    var x = Math.min(geometry.columns, Math.max(1, Math.floor((event.clientX - geometry.rect.left) / geometry.rect.width * geometry.columns) + 1));
    var y = Math.min(geometry.rows, Math.max(1, Math.floor((event.clientY - geometry.rect.top) / geometry.rect.height * geometry.rows) + 1));
    return { x: x, y: y };
  }

  function mouseCode(event) {
    var button = event.type === 'pointerup' ? 3 : event.button;
    var code = button < 0 ? 3 : button;
    if (event.shiftKey) code += 4;
    if (event.altKey) code += 8;
    if (event.ctrlKey) code += 16;
    if (event.type === 'pointermove') code += 32;
    return code;
  }

  function encodePointer(event, state, geometry) {
    if (!state || state.mouse_tracking === 'off') return null;
    if (event.type === 'pointermove' && state.mouse_tracking === 'x10') return null;
    if (event.type === 'pointermove' && state.mouse_tracking === 'button-event' && !event.buttons) return null;
    var cell = pointerCell(event, geometry);
    if (!cell) return null;
    var code = mouseCode(event);
    if (state.mouse_encoding === 'sgr') return ESC + '[<' + code + ';' + cell.x + ';' + cell.y + (event.type === 'pointerup' ? 'm' : 'M');
    if (state.mouse_encoding === 'urxvt') return ESC + '[' + (code + 32) + ';' + cell.x + ';' + cell.y + 'M';
    if (cell.x > 223 || cell.y > 223) return null;
    if (state.mouse_encoding === 'utf8') return ESC + '[M' + String.fromCharCode(code + 32, cell.x + 32, cell.y + 32);
    return new Uint8Array([27, 91, 77, code + 32, cell.x + 32, cell.y + 32]);
  }

  global.Tessera = global.Tessera || {};
  global.Tessera.ProxyInput = {
    encodeKeyboardEvent: encodeKeyboardEvent,
    encodePaste: encodePaste,
    encodeFocus: encodeFocus,
    encodePointer: encodePointer,
  };
})(window);
