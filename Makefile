
default: build

build:
	opam exec -- dune build

format:
	opam exec -- dune fmt

format-check:
	opam exec -- dune build @fmt

test:
	opam exec -- dune runtest --auto-promote

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
	opam exec -- dune $@

.PHONY: default build clean format format-check pristine test
