'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

global.window = global.window || {};
require(path.join(__dirname, '..', '..', '..', 'web', 'proxy-input.js'));
const { ProxyInput } = global.window.Tessera;

const baseState = {
  application_cursor: false,
  application_keypad: false,
  bracketed_paste: false,
  focus_reporting: false,
  mouse_tracking: 'off',
  mouse_encoding: 'default',
};

test('cursor keys, keypad, paste, and focus use only the authoritative mode state', () => {
  assert.equal(ProxyInput.encodeKeyboardEvent({ key: 'ArrowUp', code: 'ArrowUp' }, baseState), '\x1b[A');
  assert.equal(
    ProxyInput.encodeKeyboardEvent({ key: 'ArrowUp', code: 'ArrowUp' }, { ...baseState, application_cursor: true }),
    '\x1bOA',
  );
  assert.equal(
    ProxyInput.encodeKeyboardEvent({ key: '1', code: 'Numpad1' }, { ...baseState, application_keypad: true }),
    '\x1bOq',
  );
  assert.equal(ProxyInput.encodePaste('hello', { ...baseState, bracketed_paste: true }), '\x1b[200~hello\x1b[201~');
  assert.equal(ProxyInput.encodeFocus(true, { ...baseState, focus_reporting: true }), '\x1b[I');
  assert.equal(ProxyInput.encodeFocus(false, baseState), null);
});

test('mouse tracking gates events and keeps legacy mouse bytes binary', () => {
  const geometry = { columns: 80, rows: 24, rect: { left: 0, top: 0, width: 800, height: 480 } };
  const down = { type: 'pointerdown', clientX: 10, clientY: 10, button: 0, buttons: 1 };
  assert.equal(ProxyInput.encodePointer(down, baseState, geometry), null);
  const legacy = ProxyInput.encodePointer(down, { ...baseState, mouse_tracking: 'x10' }, geometry);
  assert.ok(legacy instanceof Uint8Array);
  assert.deepEqual(Array.from(legacy), [27, 91, 77, 32, 34, 33]);
  const sgr = ProxyInput.encodePointer(down, { ...baseState, mouse_tracking: 'x10', mouse_encoding: 'sgr' }, geometry);
  assert.equal(sgr, '\x1b[<0;2;1M');
  const move = { ...down, type: 'pointermove', buttons: 0 };
  assert.equal(ProxyInput.encodePointer(move, { ...baseState, mouse_tracking: 'button-event' }, geometry), null);
});
