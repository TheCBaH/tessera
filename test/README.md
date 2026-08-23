# Native expect-suite layout

Each native `ppx_expect` component lives in its own directory with its own wrapped Dune library
and a matching alias, so it can be built and run independently of the rest of the suite. `dune
build @runtest` (equivalently `make test` / `make precommit`) still runs all of them together,
plus the JSOO and Melange runtime-fixture targets in this directory.

| Directory | Alias | Library | Covers |
| --- | --- | --- | --- |
| `test/model` | `@test-model` | `tessera_test_model` | Collections/damage, Unicode boundary behaviour |
| `test/decoder` | `@test-decoder` | `tessera_test_decoder` | C0/C1/ESC framing, CSI mapping, OSC/DCS/APC/PM/SOS strings, chunking, allocation/history bound |
| `test/decoder/corpus` | `@test-decoder-corpus` | `tessera_test_decoder_corpus` | Named malformed/framing byte corpus (data-led, additive) |
| `test/renderer` | `@test-renderer` | `tessera_test_renderer` | Cursor, editing, scrolling, screens, patch/renderer invariants, allocation budgets (printable run, local edit, scroll, resize refresh, alternate-screen switch, snapshot creation) |
| `test/terminfo` | `@test-terminfo` | `tessera_test_terminfo` | Description canonicalisation, source parsing, compiled parsing |
| `test/terminfo/corpus` | `@test-terminfo-corpus` | `tessera_test_terminfo_corpus` | Named adversarial source/compiled byte corpus (data-led, additive; retained crash fixtures from `test/fuzz`) |
| `test/encoder` | `@test-encoder` | `tessera_test_encoder` | Capability-program encoding |
| `test/repaint` | `@test-repaint` | `tessera_test_repaint` | Repaint target/compile and rejection fixtures |
| `test/core` | `@test-core` | `tessera_test_core` | `Session.ingest`/`finish`, resize ordering/observation, retained sessions |
| `test/integration` | `@test-integration` | `tessera_test_integration` | Full `Patch → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply` round trip |
| `test/public` | `@test-public` | `tessera_test_public` | Public `Tessera` facade smoke/compatibility examples only |
| `test/properties` | `@test-properties` | n/a (`properties` test executable) | QCheck properties: arbitrary decoder chunking, resize/byte ingress interleavings, same-size resize refresh, checkpoint replay/branching, patch algebra, renderer invariants, source/compiled Terminfo equivalence |
| `test/fuzz` | `@test-fuzz` | n/a (`decoder_fuzz`/`terminfo_fuzz` Crowbar executables) | Native fuzzing under small policy limits: decoder never raises on arbitrary/chunked bytes or oversized malformed control strings; compiled/source Terminfo parsing never raises on arbitrary or structurally-plausible bytes |
| `test/memtrace` | `@test-memtrace` | n/a (`benchmark` executable, build-only) | Native release benchmark workload; run with `MEMTRACE=<file>` to capture an allocation trace for manual inspection |

Shared, non-test-bearing support:

| Directory | Library | Provides |
| --- | --- | --- |
| `test/support` | `tessera_test_support` | `let*`/`and*`, `with_error`/`with_error_kind`, `pp_result`, size/coord/rect/policy/slice/cell construction, `batch_of_updates` |
| `test/fixtures` | `tessera_test_fixtures` | Named compiled-terminfo byte builders |

## Dependency rules

Component suites depend on their own production library directly (e.g. `test/decoder` depends on
`tessera_decoder`, not the `tessera` facade), so the Dune dependency graph documents and partly
enforces the split: `test/model` cannot reach the decoder/renderer/core libraries, `test/decoder`
and `test/renderer` cannot reach each other or `tessera` (core), and so on. `test/integration` and `test/public` depend only on the public `tessera` facade,
demonstrating the supported composition boundary. `test/properties` drives everything through the
`tessera` facade too, but also depends directly on `tessera_foundation`/`tessera_model` for its
generators (mirroring the pattern `test/core` already uses), since those are the value-model types
its QCheck generators construct. The one exception: `test/encoder` cannot be Dune-isolated from `tessera_renderer`,
because `Encoder` and `Repaint` are both modules of the single `tessera_terminfo` library and
`Repaint` already depends on `tessera_renderer`; encoder tests simply avoid constructing
`Renderer`/`Patch` values as a convention. See `split.md` for the full table and rationale.

`test/fuzz` is a `(tests ...)` stanza (plain Crowbar executables, not `ppx_expect`), and depends
directly on `tessera_decoder`/`tessera_terminfo` like their component suites. It asserts crash-
freedom only (`Ok _ | Error _ -> ()`); any input Crowbar finds that raises is reduced to a minimal
reproduction and retained as a deterministic regression case in `test/decoder/corpus` or
`test/terminfo/corpus`, whichever component the crash was in.

`test/memtrace` is a plain `(executable ...)`, not run by `runtest`; it is built (proving it stays
buildable) but only run manually via `dune exec test/memtrace/benchmark.exe`, optionally with
`MEMTRACE=<file>` set to capture a trace and `TESSERA_MEMTRACE_ITERATIONS` to size the run. It
exercises the same operation categories -- printable run, local edit, scroll, resize refresh,
alternate-screen switch, snapshot creation -- committed as allocation budgets in
`test/renderer/allocation.ml` and `test/decoder/allocation.ml`.

## Running one layer

```
dune build @test-decoder
dune build @test-renderer
dune build @test-decoder-corpus
dune build @test-fuzz
```

`dune runtest` / `make test` / `make precommit` run everything.
