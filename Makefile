
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

.PHONY: check default build clean format format-check jsoo melange node-pty-install opam-lock precommit \
	pristine test test-jsoo-pty test-melange-pty test-node-pty
