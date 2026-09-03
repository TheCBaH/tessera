// Decodes test/node_pty/traces/<name>.json's base64-encoded `data` event byte spans back into the
// same kind of JS string node-pty's own `data` event already hands to a bridge's `push` (proven
// correct for both backends by test/node_pty, including real multi-byte graphemes). The trace
// capture side (test/node_pty/run.js's `traceRecorder`) base64-encodes via
// `Buffer.from(pendingData, 'utf8').toString('base64')`; this is its exact inverse, so every
// Playwright spec that replays a trace uses one shared module rather than reimplementing this per
// test. `atob`-free: uses `Uint8Array.fromBase64` where available (recent runtimes), else a small
// committed base64 table, then `TextDecoder('utf-8', { fatal: true })` -- `fatal` so a corrupt fixture
// fails loudly rather than silently substituting U+FFFD.

(function (root, factory) {
  var exported = factory();
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = exported;
  }
  var globalObj = typeof globalThis !== 'undefined' ? globalThis : root;
  globalObj.Tessera = Object.assign(globalObj.Tessera || {}, exported);
})(this, function () {
  'use strict';

  var BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var BASE64_INDEX = (function () {
    var table = new Array(256).fill(-1);
    for (var i = 0; i < BASE64_ALPHABET.length; i += 1) table[BASE64_ALPHABET.charCodeAt(i)] = i;
    return table;
  })();

  function base64ToBytesFallback(base64) {
    var clean = base64.replace(/[\r\n]/g, '');
    var padding = 0;
    if (clean.endsWith('==')) padding = 2;
    else if (clean.endsWith('=')) padding = 1;
    var cleanLen = clean.length - (padding > 0 ? (clean.endsWith('==') ? 2 : 1) : 0);
    var outLen = Math.floor((clean.length * 3) / 4) - padding;
    var bytes = new Uint8Array(outLen);
    var outIndex = 0;
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < cleanLen; i += 1) {
      var value = BASE64_INDEX[clean.charCodeAt(i)];
      if (value === -1) throw new Error('invalid base64 character at position ' + i);
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes[outIndex] = (buffer >> bits) & 0xff;
        outIndex += 1;
      }
    }
    return bytes;
  }

  function base64ToBytes(base64) {
    if (typeof Uint8Array.fromBase64 === 'function') return Uint8Array.fromBase64(base64);
    return base64ToBytesFallback(base64);
  }

  function decodeTraceBytes(base64) {
    var bytes = base64ToBytes(base64);
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }

  return { decodeTraceBytes: decodeTraceBytes };
});
