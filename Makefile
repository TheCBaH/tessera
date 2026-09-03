
default: build

build:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build

jsoo:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build @jsoo

melange:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build @tessera-melange

format:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune fmt

format-check:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build @fmt

test:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune runtest

# Installs the locked node-pty test workspace (test/node_pty/package-lock.json), including its native
# addon build. Not part of `build`/`test`/`check`: it needs a Node runtime and network access to the npm
# registry the first time, matching how `opam install` for the OCaml side is a separate, one-time step.
# See test/README.md.
node-pty-install:
	cd test/node_pty && npm ci

# Opt-in runtime suites that drive real dialog/whiptail/shell fixtures through a Linux PTY via
# node-pty, for the js_of_ocaml and Melange backends respectively. Require
# `make node-pty-install` first; not part of `test`/`check` until Node is part of the CI contract.
test-jsoo-pty:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build @test-jsoo-pty

test-melange-pty:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build @test-melange-pty

test-node-pty: test-jsoo-pty test-melange-pty

# Regenerates test/node_pty/traces/*.json, the committed real-terminal-output fixtures
# test/web_rendering_traces replays natively (no PTY, no Node needed to run that replay). An
# explicit developer command, like TESSERA_NODE_PTY_WRITE_GOLDENS above: review the diff before
# committing. Requires `make node-pty-install` first.
node-pty-capture-traces:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build test/node_pty/jsoo_runner.bc.js
	cd test/node_pty && TESSERA_NODE_PTY_WRITE_TRACES=1 node run.js --backend jsoo \
		--bridge ../../_build/default/test/node_pty/jsoo_runner.bc.js

# Installs the locked Playwright workspace (test/web_render_playwright/package-lock.json) and its
# pinned Chromium binary -- split into two targets, like the two independent CI caches in
# .github/workflows/build.yml (one for node_modules, one for the browser download), so either can be
# skipped when its own cache already hit. `playwright-install` runs both, for local development. Not
# part of `build`/`test`/`check`: needs a Node runtime and network access. The locally locked
# `./node_modules/.bin/playwright install` (never a bare unpinned `npx playwright install`, which
# could silently fetch an unrelated version if the local install is missing) fails loudly instead,
# matching `node-pty-install`'s existing requirement style. See test/README.md.
web-render-npm-install:
	cd test/web_render_playwright && npm ci

playwright-browser-install:
	cd test/web_render_playwright && ./node_modules/.bin/playwright install chromium

playwright-install: web-render-npm-install playwright-browser-install

# Regenerates test/web_render_playwright/fixtures/*.json, the committed synthetic edge-case frame
# corpus (test/web_render_fixtures/gen_fixtures.ml). An explicit developer command, like
# node-pty-capture-traces above: review the diff before committing.
web-render-gen-fixtures:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build test/web_render_fixtures/gen_fixtures.exe
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune exec test/web_render_fixtures/gen_fixtures.exe

# Regenerates test/web_render_playwright/goldens/<case>-html.frames.jsonl, the committed per-case
# ordered-frame wire-stream oracle (test/web_render_playwright/gen_goldens.ml). An explicit developer
# command; review the diff before committing.
web-render-gen-goldens:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build test/web_render_playwright/gen_goldens.exe
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune exec test/web_render_playwright/gen_goldens.exe

# The browser driver, HTML target, and Playwright structural/screenshot matrix.
# Requires `make playwright-install` first; not part of `test`/`check` until Node/a browser
# are part of the CI contract (see test-node-pty above for the same convention). Runs the
# driver/trace-decoder unit tests first (fastest, no browser), then builds the jsoo/Melange browser
# artifacts, then the full Playwright matrix.
test-web-render:
	cd test/web_render_playwright && node --test tests/*.node.test.js
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build test/web_render_playwright/jsoo_bridge.bc.js @web-render-melange
	cd test/web_render_playwright && ./node_modules/.bin/playwright test

# Explicit developer command to refresh committed screenshot baselines after a reviewed rendering
# change -- like test/proxy_tmux/regenerate_goldens.sh, never runs in CI. Review the diff before
# committing.
playwright-update-screenshots:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune build test/web_render_playwright/jsoo_bridge.bc.js @web-render-melange
	cd test/web_render_playwright && ./node_modules/.bin/playwright test --update-snapshots

# Deliberately excludes test-node-pty and test-web-render: both need a Node runtime (and, for
# test-web-render, a pinned Chromium install) that a plain OCaml-only checkout does not have.
check: format build test jsoo melange format-check

precommit: check
	git diff --check

pristine:
	@status="$$(git status --short)"; \
	if [ -n "$$status" ]; then \
		echo "Repository changed:" >&2; \
		printf '%s\n' "$$status" >&2; \
		git -c core.pager=cat diff --no-ext-diff >&2; \
		git -c core.pager=cat diff --cached --no-ext-diff >&2; \
		exit 1; \
	fi

clean:
	ERR_TRACE_TEST_MELANGE=true opam exec -- dune $@

# Regenerates every *.opam.locked file (opam-lock plugin) against the current switch, pinning the
# exact transitive dependency versions `opam install --locked <package>.opam.locked` would install.
# tessera.opam has no lock file: its only non-test dependency, err_trace, is vendored and pinned via
# the vendor/err_trace git submodule commit instead, so opam never sees it as an installable package.
opam-lock:
	opam lock .

.PHONY: check default build clean format format-check jsoo melange node-pty-capture-traces \
	node-pty-install opam-lock playwright-browser-install playwright-install \
	playwright-update-screenshots precommit pristine test test-jsoo-pty test-melange-pty \
	test-node-pty test-web-render web-render-gen-fixtures web-render-gen-goldens web-render-npm-install
