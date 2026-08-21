# Tessera

[![CI status](https://github.com/TheCBaH/tessera/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/TheCBaH/tessera/actions/workflows/build.yml?query=branch%3Amain)
[![Create a Codespace](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new?repo=TheCBaH%2Ftessera&ref=main)

Tessera is a portable, pure OCaml core for decoding terminal output into an
immutable logical screen. It is scoped to an xterm-256color core profile and
has no I/O, scheduler, filesystem, JavaScript-binding, or C-stub dependency.

The library is organised into wrapped Dune components:

- `tessera.foundation` supplies checked portable value types and policy.
- `tessera.model` owns styles, Unicode graphemes, cells, updates, and effects.
- `tessera.decoder` incrementally accepts text and C0 control slices.
- `tessera.renderer` maintains the immutable logical grid and emits lineage
  and generation-aware patches.
- `tessera` is the public facade.

`err_trace` is vendored as the `vendor/err_trace` submodule. Clone with
`--recurse-submodules`, or run `git submodule update --init --recursive` after
cloning.

## Development

The devcontainer uses OCaml 4.14.3 by default. CI builds on x86_64 with OCaml
4.14.3 and 5.5.0.

```sh
make build       # build every Dune target
make test        # run tests and promote accepted expect outputs
make format      # format sources
make format-check
```
