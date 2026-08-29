#!/usr/bin/env node
'use strict';

// The Node runner: owns the Linux PTY boundary via node-pty, drives dialog/whiptail/VT
// fixtures through it, and asserts the result against Tessera's own logical-screen golden, produced by
// the shared OCaml bridge (test/node_pty_bridge/bridge.ml). Shared between the js_of_ocaml and Melange
// backends -- the only thing that differs per backend is which compiled bridge module `--bridge` points
// at; everything here (scenario manifest, node-pty spawning, readiness/timeout handling, golden
// comparison) is backend-neutral.

const fs = require('fs');
const os = require('os');
const path = require('path');
const pty = require('node-pty');

function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--backend') result.backend = argv[(i += 1)];
    else if (argv[i] === '--bridge') result.bridge = argv[(i += 1)];
    else {
      process.stderr.write(`unrecognized argument: ${argv[i]}\n`);
      process.exit(64);
    }
  }
  if (!result.backend || !result.bridge) {
    process.stderr.write('usage: node run.js --backend <jsoo|melange> --bridge <path-to-compiled-bridge>\n');
    process.exit(64);
  }
  return result;
}

const { backend, bridge } = parseArgs(process.argv.slice(2));
const Bridge = require(path.resolve(bridge));

const FIXTURE = path.join(__dirname, 'fixture.sh');
const GOLDENS_DIR = path.join(__dirname, 'goldens');
const REGENERATE = process.env.TESSERA_NODE_PTY_WRITE_GOLDENS === '1';
const SCENARIO_TIMEOUT_MS = 30000;
const POLL_INTERVAL_MS = 50;
const COLUMNS = 40;
const ROWS = 10;
// A completion sentinel sent as an OSC window-title escape (invisible to the rendered grid Tessera
// tracks) rather than through TESSERA_TEST_DONE_FILE alone: that file is a side channel independent of
// the PTY byte stream Bridge.push() consumes, so observing it gives no guarantee that everything the
// fixture wrote beforehand (e.g. a shell's echo of a just-typed command) has actually reached the
// Bridge yet. Waiting for this sentinel in Bridge.snapshotText() instead -- the same technique already
// used below for readyText -- guarantees every byte written earlier in that same ordered stream has
// already been applied, since it travels through the identical channel.
const DONE_TITLE = 'tessera-node-pty-done';

const cases = [
  {
    // Down is the terminal's own kcud1 capability, not a fixed byte sequence: this container's
    // xterm-256color terminfo defines arrow keys in SS3 form (`ESC O B`), not the CSI form (`ESC [ B`)
    // seen on many other systems -- `infocmp xterm-256color` is the source of truth if this ever needs
    // to change.
    name: 'dialog-menu-submit',
    input: { keys: ['\x1bOB', '\r'] },
    resize: null,
    readyText: 'Dialog menu',
    expectedResult: 'second',
  },
  {
    name: 'whiptail-menu-cancel',
    input: { keys: ['\x1b'] },
    resize: null,
    readyText: 'Whiptail menu',
    expectedResult: 'cancel\n',
  },
  {
    name: 'vt-form-edit',
    input: { literal: 'proxy value' },
    resize: null,
    readyText: 'FORM: enter value>',
    expectedResult: 'proxy value\n',
  },
  {
    name: 'vt-scroll-redraw',
    input: { keys: ['\r'] },
    resize: null,
    readyText: 'SCROLL START',
    expectedResult: 'redrawn\n',
  },
  {
    name: 'vt-resize-redraw',
    input: { keys: ['\r'] },
    resize: { columns: 60, rows: 16 },
    readyText: 'RESIZE WAITING',
    expectedResult: '16 60\n',
  },
  {
    name: 'vt-shell-session',
    input: {
      literal:
        'echo shell-command-ran > "$TESSERA_RESULT_PATH"; printf \'\\033]0;%s\\007\' "$TESSERA_TEST_DONE_TITLE"; : > "$TESSERA_TEST_DONE_FILE"; while [ ! -f "$TESSERA_TEST_CAPTURED_FILE" ]; do sleep 0.05; done',
    },
    resize: null,
    readyText: 'TESSERA$',
    expectedResult: 'shell-command-ran\n',
  },
];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, description, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (predicate()) return;
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${description}`);
    await sleep(POLL_INTERVAL_MS);
  }
}

function containsText(haystack, needle) {
  return haystack.indexOf(needle) !== -1;
}

function readFileIfPresent(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function runCase(testCase) {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tessera-node-pty-'));
  const resultFile = path.join(workDir, 'result');
  const readyFile = path.join(workDir, 'ready');
  const doneFile = path.join(workDir, 'done');
  const capturedFile = path.join(workDir, 'captured');

  const createError = Bridge.create(COLUMNS, ROWS);
  if (createError) throw new Error(`bridge create failed: ${createError}`);

  const env = Object.assign({}, process.env, {
    TERM: 'xterm-256color',
    LC_ALL: 'C.UTF-8',
    TESSERA_TEST_READY_FILE: readyFile,
    TESSERA_TEST_DONE_FILE: doneFile,
    TESSERA_TEST_CAPTURED_FILE: capturedFile,
    TESSERA_TEST_DONE_TITLE: DONE_TITLE,
  });

  const child = pty.spawn('/bin/sh', [FIXTURE, testCase.name, resultFile], {
    name: 'xterm-256color',
    cols: COLUMNS,
    rows: ROWS,
    cwd: workDir,
    env,
  });

  let exited = false;
  let pushFailure = null;
  child.onData((data) => {
    const error = Bridge.push(data);
    if (error && !pushFailure) pushFailure = new Error(`push failed: ${error}`);
  });
  child.onExit(() => {
    exited = true;
  });

  const cleanup = () => {
    if (!exited) {
      try {
        child.kill();
      } catch (_error) {
        /* already gone */
      }
    }
    fs.rmSync(workDir, { recursive: true, force: true });
  };

  const body = (async () => {
    await waitFor(() => fs.existsSync(readyFile), `${testCase.name} ready file`, SCENARIO_TIMEOUT_MS);
    if (pushFailure) throw pushFailure;
    await waitFor(
      () => containsText(Bridge.snapshotText(), testCase.readyText),
      `${testCase.name} ready text ${JSON.stringify(testCase.readyText)}`,
      SCENARIO_TIMEOUT_MS
    );
    if (pushFailure) throw pushFailure;
    // Give a freshly drawn full-screen program a moment to finish installing its own input handling
    // (e.g. ncurses' keypad/escape-sequence recognition) before keys start arriving -- otherwise an
    // escape-prefixed key sent immediately on the first sighting of the ready text can race a
    // still-settling curses widget and be misread as a lone Escape.
    await sleep(150);

    if (testCase.resize) {
      child.resize(testCase.resize.columns, testCase.resize.rows);
      const resizeError = Bridge.resize(testCase.resize.columns, testCase.resize.rows);
      if (resizeError) throw new Error(`resize failed: ${resizeError}`);
      // Let the SIGWINCH this resize raises actually reach the child before its next read -- node-pty's
      // resize() issues the ioctl synchronously, but signal delivery to the child process is not
      // synchronous with that call returning.
      await sleep(50);
    }

    if (testCase.input.keys) {
      for (const key of testCase.input.keys) child.write(key);
    } else {
      child.write(testCase.input.literal);
      child.write('\r');
    }

    await waitFor(() => fs.existsSync(doneFile), `${testCase.name} done file`, SCENARIO_TIMEOUT_MS);
    if (pushFailure) throw pushFailure;
    await waitFor(
      () => containsText(Bridge.snapshotText(), `title=${DONE_TITLE}`),
      `${testCase.name} done sentinel`,
      SCENARIO_TIMEOUT_MS
    );
    if (pushFailure) throw pushFailure;

    const resultContents = readFileIfPresent(resultFile);
    if (resultContents === null) throw new Error('fixture signalled done without writing a result file');
    const snapshot = Bridge.snapshotText();
    fs.writeFileSync(capturedFile, '');

    // Give the fixture a moment to observe capturedFile and unwind (matters for the curses cases,
    // which restore terminal mode as they exit) before the finish() call below.
    await sleep(200);
    if (!exited) {
      try {
        child.kill();
      } catch (_error) {
        /* already gone */
      }
      await waitFor(() => exited, `${testCase.name} child exit`, SCENARIO_TIMEOUT_MS);
    }
    const finishError = Bridge.finish();
    if (finishError) throw new Error(`finish failed: ${finishError}`);
    if (pushFailure) throw pushFailure;

    return { resultContents, snapshot };
  })();

  return body.finally(cleanup);
}

function compareGolden(testCase, snapshot) {
  const goldenPath = path.join(GOLDENS_DIR, `${testCase.name}.txt`);
  if (REGENERATE) {
    fs.writeFileSync(goldenPath, snapshot);
    return 'regenerated';
  }
  const golden = fs.readFileSync(goldenPath, 'utf8');
  if (golden !== snapshot) {
    throw new Error(`${testCase.name} snapshot golden mismatch:\nexpected:\n${golden}\ngot:\n${snapshot}`);
  }
  return 'matched';
}

async function main() {
  process.stdout.write(`backend=${backend}\n`);
  for (const testCase of cases) {
    const { resultContents, snapshot } = await runCase(testCase);
    if (resultContents !== testCase.expectedResult) {
      throw new Error(
        `${testCase.name} result mismatch: expected ${JSON.stringify(testCase.expectedResult)}, got ${JSON.stringify(
          resultContents
        )}`
      );
    }
    const status = compareGolden(testCase, snapshot);
    process.stdout.write(`${testCase.name}: result and snapshot golden ${status}\n`);
  }
}

main().then(
  () => process.exit(0),
  (error) => {
    process.stderr.write(`${error && error.stack ? error.stack : error}\n`);
    process.exit(1);
  }
);
