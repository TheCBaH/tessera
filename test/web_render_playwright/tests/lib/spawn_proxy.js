// Shared helper for spawning a real `tessera-proxy` under a real controlling terminal (node-pty --
// confirmed empirically that tessera-proxy cannot start at all under a plain `child_process.spawn` with
// pipes, since it requires a real terminal to query/enter raw mode on), used by both
// web_driver_reconnect.node.test.js (plain node --test) and web_proxy.spec.js (Playwright). Every caller
// gets a fixed, deterministic child command (`/bin/cat`, not the user's real shell) and the
// TESSERA_PROXY_WEB_PORT/_TOKEN/_READY_FILE deterministic test hook (web_server.mli's `create` doc
// comment) for a race-free readiness signal -- no sleeping, no stderr-scraping.

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const pty = require('node-pty');

const PROXY_BIN = path.join(__dirname, '..', '..', '..', '..', '_build', 'default', 'lib', 'proxy_linux', 'proxy.exe');

function waitForFile(filePath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (fs.existsSync(filePath)) {
        resolve(fs.readFileSync(filePath, 'utf8').trim());
        return;
      }
      if (Date.now() > deadline) {
        reject(new Error(`timed out waiting for ${filePath}`));
        return;
      }
      setTimeout(poll, 20);
    };
    poll();
  });
}

// Spawns tessera-proxy with a fresh ephemeral port and a caller-chosen fixed token, waits for its
// ready file, and returns the pty handle plus the parsed bootstrap URL/port/token.
async function spawnProxy({ token, cols = 80, rows = 24, extraEnv = {} } = {}) {
  const readyFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tessera-web-proxy-')), 'ready.txt');
  const proc = pty.spawn(PROXY_BIN, ['/bin/cat'], {
    name: 'xterm',
    cols,
    rows,
    env: Object.assign({}, process.env, extraEnv, {
      TESSERA_PROXY_WEB_PORT: '0',
      TESSERA_PROXY_WEB_TOKEN: token,
      TESSERA_PROXY_WEB_READY_FILE: readyFile,
    }),
  });
  const bootstrapUrl = await waitForFile(readyFile, 5000);
  const url = new URL(bootstrapUrl);
  return { proc, bootstrapUrl, port: url.port, token: url.searchParams.get('token') };
}

function killProxy(proc) {
  try {
    proc.kill();
  } catch (err) {
    /* already gone */
  }
}

module.exports = { spawnProxy, killProxy, waitForFile };
