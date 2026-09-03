// Unit tests for web/tessera-trace-decoder.js: plain `node --test`, no browser. Proves
// decodeTraceBytes is the exact inverse of test/node_pty/run.js's traceRecorder encoding
// (`Buffer.from(pendingData, 'utf8').toString('base64')`), including a real multi-byte grapheme, not
// just ASCII -- mirroring the kind of fixture test/model/unicode.ml/test/json_codec already use.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { decodeTraceBytes } = require(path.join(__dirname, '..', '..', '..', 'web', 'tessera-trace-decoder.js'));

test('decodes plain ASCII', () => {
  const original = 'hello, tessera';
  const base64 = Buffer.from(original, 'utf8').toString('base64');
  assert.equal(decodeTraceBytes(base64), original);
});

test('decodes a real multi-byte grapheme (an emoji outside the BMP, 4 UTF-8 bytes)', () => {
  const original = 'status: \u{1f642} ready';
  const base64 = Buffer.from(original, 'utf8').toString('base64');
  assert.equal(decodeTraceBytes(base64), original);
});

test('decodes a combining-character grapheme (base + combining acute, 3 UTF-8 bytes)', () => {
  const original = 'café'; // "café" spelled with a combining acute accent
  const base64 = Buffer.from(original, 'utf8').toString('base64');
  assert.equal(decodeTraceBytes(base64), original);
});

test('decodes an empty string', () => {
  assert.equal(decodeTraceBytes(''), '');
});

test('throws on malformed UTF-8 rather than silently substituting U+FFFD', () => {
  // A lone continuation byte (0x80) is never valid at the start of a UTF-8 sequence.
  const bytes = Uint8Array.from([0x80]);
  const base64 = Buffer.from(bytes).toString('base64');
  assert.throws(() => decodeTraceBytes(base64));
});
