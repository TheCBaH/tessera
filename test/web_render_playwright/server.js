#!/usr/bin/env node
'use strict';

// Plain Node `http` static server (no Express) for the Playwright workspace. Serves:
//  - web/ (the shipped, framework-free browser assets: driver, decoder, HTML target, stylesheet);
//  - the compiled jsoo_bridge.bc.js and the Melange melange-output tree (dune build artifacts);
//  - the vendored font from node_modules/@fontsource/jetbrains-mono;
//  - test/node_pty/traces/*.json (the committed real-terminal-output fixtures) and
//    test/web_render_playwright/fixtures/*.json (the synthetic edge-case corpus);
//  - pages/index.html, with a generated <script type="importmap"> injected before any other script.
//
// The import map exists because dune's Melange `(module_systems (esm .mjs))` output uses bare
// package-name specifiers (e.g. `import ... from "tessera.foundation/limits.mjs"`) for any library
// that is an *installed* package (declares a public_name) -- the same convention dune already
// mirrors into a `node_modules/<package>/...` tree inside the emit target directory, resolvable by
// Node's own bare-specifier algorithm. A browser's native ES module loader has no such algorithm: it
// accepts only relative/absolute URL specifiers. An import map is the standard, declarative,
// non-bundling way to teach a browser the same `<package>/` -> URL mapping dune already encodes as a
// directory layout -- it transforms no JS, so it stays inside this suite's "no bundler or shim"
// constraint. Modules belonging to *this* project (no public_name, e.g. bridge_runner.mjs,
// melange_bridge.mjs) already use plain relative imports and need no map entry.

const fs = require('fs');
const http = require('http');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD_DIR = path.join(ROOT, '_build', 'default', 'test', 'web_render_playwright');
const MELANGE_DIR = path.join(BUILD_DIR, 'melange-output');
const MELANGE_NODE_MODULES = path.join(MELANGE_DIR, 'node_modules');
const WEB_DIR = path.join(ROOT, 'web');
const FONT_FILES_DIR = path.join(__dirname, 'node_modules', '@fontsource', 'jetbrains-mono', 'files');
const TRACES_DIR = path.join(ROOT, 'test', 'node_pty', 'traces');
const FIXTURES_DIR = path.join(__dirname, 'fixtures');
const PAGES_DIR = path.join(__dirname, 'pages');

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
};

function contentTypeFor(filePath) {
  return CONTENT_TYPES[path.extname(filePath)] || 'application/octet-stream';
}

// Only single-level package directories exist under a dune Melange emit's node_modules (confirmed by
// inspecting the actual build output; no @scope/pkg nesting occurs here), so a flat one-level scan is
// sufficient -- this generates the map from whatever dune actually emitted, rather than a hand
// maintained list that could silently drift from the real dependency graph.
function buildImportMap() {
  const imports = {};
  let entries = [];
  try {
    entries = fs.readdirSync(MELANGE_NODE_MODULES, { withFileTypes: true });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return { imports };
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    imports[entry.name + '/'] = '/melange/node_modules/' + entry.name + '/';
  }
  return { imports };
}

function safeJoin(base, requestPath) {
  const resolved = path.normalize(path.join(base, requestPath));
  if (resolved !== base && !resolved.startsWith(base + path.sep)) return null;
  return resolved;
}

function sendFile(res, filePath) {
  fs.readFile(filePath, (error, data) => {
    if (error) {
      res.writeHead(error.code === 'ENOENT' ? 404 : 500, { 'Content-Type': 'text/plain' });
      res.end(error.code === 'ENOENT' ? 'not found' : 'server error');
      return;
    }
    res.writeHead(200, { 'Content-Type': contentTypeFor(filePath) });
    res.end(data);
  });
}

function sendIndex(res) {
  const indexPath = path.join(PAGES_DIR, 'index.html');
  fs.readFile(indexPath, 'utf8', (error, html) => {
    if (error) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('server error');
      return;
    }
    const importMapScript = '<script type="importmap">' + JSON.stringify(buildImportMap()) + '</script>';
    const injected = html.replace('<!--IMPORTMAP-->', importMapScript);
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(injected);
  });
}

const ROUTES = [
  { prefix: '/web/', dir: WEB_DIR },
  { prefix: '/melange/', dir: MELANGE_DIR },
  { prefix: '/fonts/', dir: FONT_FILES_DIR },
  { prefix: '/traces/', dir: TRACES_DIR },
  { prefix: '/fixtures/', dir: FIXTURES_DIR },
];

function requestHandler(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const pathname = decodeURIComponent(url.pathname);

  if (pathname === '/' || pathname === '/index.html' || pathname === '/pages/index.html') {
    sendIndex(res);
    return;
  }

  if (pathname === '/jsoo/jsoo_bridge.bc.js') {
    sendFile(res, path.join(BUILD_DIR, 'jsoo_bridge.bc.js'));
    return;
  }

  for (const route of ROUTES) {
    if (pathname.startsWith(route.prefix)) {
      const rest = pathname.slice(route.prefix.length);
      const filePath = safeJoin(route.dir, rest);
      if (filePath === null) {
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end('bad request');
        return;
      }
      sendFile(res, filePath);
      return;
    }
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('not found');
}

function main() {
  const port = Number(process.env.PORT) || 4173;
  const server = http.createServer(requestHandler);
  server.listen(port, () => {
    process.stdout.write(`web_render_playwright server listening on http://localhost:${port}\n`);
  });
}

if (require.main === module) main();

module.exports = { requestHandler, buildImportMap };
