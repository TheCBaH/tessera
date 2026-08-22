
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

.PHONY: check default build clean format format-check jsoo melange precommit pristine test
