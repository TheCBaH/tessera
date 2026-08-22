# Native expect-suite layout

Each native `ppx_expect` component lives in its own directory with its own wrapped Dune library
and a matching alias, so it can be built and run independently of the rest of the suite. `dune
build @runtest` (equivalently `make test` / `make precommit`) still runs all of them together,
plus the JSOO and Melange runtime-fixture targets in this directory.

| Directory | Alias | Library | Covers |
| --- | --- | --- | --- |
| `test/model` | `@test-model` | `tessera_test_model` | Collections/damage, Unicode boundary behaviour |
| `test/decoder` | `@test-decoder` | `tessera_test_decoder` | C0/C1/ESC framing, CSI mapping, OSC/DCS/APC/PM/SOS strings, chunking |
| `test/decoder/corpus` | `@test-decoder-corpus` | `tessera_test_decoder_corpus` | Named malformed/framing byte corpus (data-led, additive) |
| `test/renderer` | `@test-renderer` | `tessera_test_renderer` | Cursor, editing, scrolling, screens, patch/renderer invariants, allocation budget |
| `test/terminfo` | `@test-terminfo` | `tessera_test_terminfo` | Description canonicalisation, source parsing, compiled parsing |
| `test/encoder` | `@test-encoder` | `tessera_test_encoder` | Capability-program encoding |
| `test/repaint` | `@test-repaint` | `tessera_test_repaint` | Repaint target/compile and rejection fixtures |
| `test/core` | `@test-core` | `tessera_test_core` | `Session.ingest`/`finish`, resize ordering/observation, retained sessions |
| `test/integration` | `@test-integration` | `tessera_test_integration` | Full `Patch → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply` round trip |
| `test/public` | `@test-public` | `tessera_test_public` | Public `Tessera` facade smoke/compatibility examples only |

Shared, non-test-bearing support:

| Directory | Library | Provides |
| --- | --- | --- |
| `test/support` | `tessera_test_support` | `let*`/`and*`, `with_error`/`with_error_kind`, `pp_result`, size/coord/rect/policy/slice/cell construction, `batch_of_updates` |
| `test/fixtures` | `tessera_test_fixtures` | Named compiled-terminfo byte builders |

## Dependency rules

Component suites depend on their own production library directly (e.g. `test/decoder` depends on
`tessera_decoder`, not the `tessera` facade), so the Dune dependency graph documents and partly
enforces the split: `test/model` cannot reach the decoder/renderer/core libraries, `test/decoder`
and `test/renderer` cannot reach each other or `tessera` (core), and so on. `test/integration` and
`test/public` depend only on the public `tessera` facade, demonstrating the supported composition
boundary. The one exception: `test/encoder` cannot be Dune-isolated from `tessera_renderer`,
because `Encoder` and `Repaint` are both modules of the single `tessera_terminfo` library and
`Repaint` already depends on `tessera_renderer`; encoder tests simply avoid constructing
`Renderer`/`Patch` values as a convention. See `split.md` for the full table and rationale.

## Running one layer

```
dune build @test-decoder
dune build @test-renderer
dune build @test-decoder-corpus
```

`dune runtest` / `make test` / `make precommit` run everything.
