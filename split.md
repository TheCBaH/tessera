# Native expect-suite split — implementation plan

## Objective and boundary

Close the first open item in `.ai/terminal-todo.md` section 5 by replacing the
two broad native inline-test libraries with independently runnable native
`ppx_expect` component, core, integration, and fixture/corpus targets.  Keep
the public-facade suite separate and retain its role as the public API
compatibility boundary.

This milestone is a test-layout refactor.  It must not change library APIs,
terminal semantics, committed expect output, or the existing JSOO/Melange
runtime-fixture targets.  QCheck, fuzzing, allocation/memtrace expansion, and
adapter conformance are separate unchecked TODO items and are not pulled into
this change.  The one existing allocation expect test moves with renderer
coverage; it is not represented as the future allocation-regression target.

## Baseline to preserve

At the start of the change, `test/dune` defines these native inline-test
libraries:

- `tessera_expect`, containing the 50-test `grid_test.ml` monolith.  It mixes
  collection/model tests, decoder protocol fixtures, renderer transitions,
  session composition, and one local-allocation assertion.
- `tessera_public_expect`, containing `public_api_test.ml`.  Besides one
  facade session test, it currently holds terminfo source/compiled fixtures,
  encoder fixtures, and controlled-repaint fixtures.

`make test` runs `dune runtest`, and the current baseline passes.  Preserve
the existing helper behaviour (`Fmt.result`, module-owned printers, borrowed
slice construction, deterministic policy) and every `[%expect]` body exactly
unless a formatting-only namespace change makes an update necessary.

## Target layout and Dune ownership

Create the documented test structure, using one wrapped Dune library with
`(inline_tests (modes byte native))` per native expect suite:

```text
test/
  support/                 # shared test-only helpers; no inline tests
  model/                   # collections, IDs/policy bounds, Unicode fixtures
  decoder/                 # c0_esc, csi, strings, chunking
    corpus/                # retained malformed/framing corpus data and runner
  renderer/                # cursor, editing, scrolling, styles, screens,
                           # invariants (including Patch.compose mechanics),
                           # existing local allocation fixture
  terminfo/                # source and compiled parser fixtures
  encoder/                 # capability-program and encoded-byte fixtures
  repaint/                 # target/compiler and controlled output fixtures
  core/                    # Session.finish, ingress, retention,
                           # session/Patch.compose equivalence
  integration/             # decode → render and controlled round-trip flows
  fixtures/                # reusable named fixture data/builders, no tests
  public/                  # the independent facade test only
```

Use clear, stable library names such as `tessera_test_decoder` and a matching
test alias for each suite (for example `@test-decoder`).  The exact aliases
must be listed in `test/dune` comments or a short `test/README.md` so a
contributor can run one layer without knowing internal Dune names.  Keep the
default `@runtest` aggregate, therefore `make test` and `make precommit`, as
the full native-expect entry points.

Dune dependencies are part of the split’s enforcement, not just build
plumbing:

| Target | Permitted production dependencies | Must not depend on |
| --- | --- | --- |
| `model` | foundation, model | decoder, renderer, core, terminfo |
| `decoder`, `decoder/corpus` | support/fixtures, foundation, model, decoder | renderer, core |
| `renderer` | support/fixtures, foundation, model, renderer | decoder, core |
| `terminfo` | support/fixtures, foundation, model, terminfo | core/session |
| `encoder` | support/fixtures, foundation, model, terminfo | decoder, session/core |
| `repaint` | support/fixtures, foundation, model, renderer, terminfo | decoder, session |
| `core` | support/fixtures, foundation, model, decoder, renderer, core | terminfo/repaint unless its assertion needs it |
| `integration` | the public `tessera` facade plus support/fixtures | direct internal library imports |
| `public` | public `tessera` facade only (and test formatting support) | all `Tessera_*` implementation libraries |

`encoder` cannot be Dune-isolated from `renderer`: `Encoder` and `Repaint` are
both modules of the single `tessera_terminfo` library, and `Repaint` already
depends on `Tessera_renderer.Patch`, so any test target depending on
`tessera_terminfo` transitively links `tessera_renderer` regardless of which
module it actually calls.  Treat "encoder tests must not construct
`Renderer`/`Patch` values" as a code-review convention for this row, not a
Dune-graph guarantee — splitting `tessera_terminfo` into separate production
libraries to make it enforceable is out of scope for this test-layout change.

Do not make `support` a back door for cross-layer production imports.  It may
provide value constructors, borrowed-slice/policy setup, result printing,
assertion adapters, and fixture loading only; component-specific operations
remain in their owning suite.  Prefer a small `.mli` for support and fixtures
when it helps enforce that boundary.

## Extract and classify existing coverage

1. Introduce `test/support` first and move the duplicated primitives from
   `grid_test.ml` and `public_api_test.ml`: `let*`/`and*`, error rendering,
   checked unsigned values, size/coordinate/rectangle construction, policy,
   slices, update-batch construction, and stable `Fmt.result` wrappers.
   Separate helpers by the production layer they actually need so the support
   library itself stays low-level.

2. Move the initial collection/damage and persistent-page tests from
   `grid_test.ml` to `test/model`; retain Unicode boundary behaviour there
   only when it tests `Model.Unicode` directly.  Put renderer-owned page
   sharing/snapshot behaviour under renderer rather than model.

3. Split the decoder tests into `c0_esc.ml`, `csi.ml`, `strings.ml`, and
   `chunking.ml`.  In particular, place C0/C1/ESC and cancellation coverage
   with framing, CSI mapping/limits/DEC modes with CSI, OSC/DCS/APC/PM/SOS and
   EOF diagnostics with strings, and whole-vs-split/UTF-8/grapheme cases with
   chunking.  These files must call `Decoder.feed`/`finish` only and must not
   construct a renderer state.

4. Create `test/decoder/corpus` as its own native fixture target.  This is
   additive breadth, not a relocation: every existing malformed/cancellation/
   EOF-diagnostic `%expect_test` named in step 3 (for example "oversized
   strings discard through their terminator", "decoder discards CSI sequences
   above the parameter limit", "decoder cancellation discards incomplete OSC
   and CSI", "decoder reports unterminated control strings only at EOF",
   "decoder frames unsupported control strings") stays in its step-3 component
   file with its existing name and expect body.  Corpus instead adds named
   byte cases — multiple variants per category (malformed CSI, oversized and
   unsupported control strings, fragmented terminators, C1 framing,
   cancellations, invalid UTF-8, unterminated EOF) driven through a small
   shared runner as data, not as one hand-written `%expect_test` per case.
   Store input as visible escaped text or hex with an identifier and expected
   diagnostic/update projection; do not hide protocol meaning in anonymous
   literals.  The corpus runner may reuse the decoder assertion helper but
   must remain separately runnable and data-led.  Seeding the data table from
   the byte inputs already used in step 3's tests is fine; moving those tests
   themselves out of their component file is not.  This establishes the
   retained-corpus seam needed by the later fuzz milestone.

5. Split renderer tests by behaviour into cursor, editing, scrolling, styles,
   screens, and invariants.  Move resize/no-reflow/full-damage and
   same-geometry refresh coverage to renderer; retain the existing warmed
   local allocation assertion in `renderer/allocation.ml`.  Renderer fixtures
   build `Update.Batch` directly and never decode bytes.  Put the two existing
   `Renderer.Patch.compose` mechanics tests ("patch composition overlays
   cells and presentation" and "same-size resize is a full refresh and patch
   composition barrier") in `renderer/invariants.ml`: both build `Patch.t`
   values or apply updates directly with no `Session` involved, so per step 8
   they are renderer-owned, not core-owned.

6. Extract Terminfo source parsing, compiled/extended parsing, malformed
   bounds, and `use=` resolution from the public test into `test/terminfo`.
   Extract encoded capabilities, unsupported capability-language forms, and
   unsupported update failures into `test/encoder`.  Reuse named compiled
   terminfo byte builders from `test/fixtures`, not the public suite.

7. Move `Repaint.initial`/`compile` target state and rejection fixtures to
   `test/repaint`.  Move the complete
   `Patch → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply`
   assertions to `test/integration`: they intentionally exercise several
   components and should not weaken their isolated suites.  The integration
   target should depend on `Tessera` only, demonstrating the supported
   composition boundary.

8. Move `Session.ingest`, resize ordering/observation, `Session.finish`, and
   retained-session assertions to `test/core`.  Core tests may compose
   decoder and renderer where the assertion is specifically about session
   equivalence, but renderer-only damage and decoder-only framing coverage
   belongs in the respective component target.  `core/`'s `Patch.compose`
   role is limited to session/Patch.compose equivalence (composing results
   from two `Session.ingest` calls and checking it equals one direct
   `Patch.compose`) — a category the current baseline does not yet contain;
   the existing pure-mechanics `Patch.compose` tests move to
   `renderer/invariants.ml` per step 5, not here.

9. Curate `test/public_api_test.ml` (or move it under `test/public/`) to
   compact facade-only examples: public construction and aliases, a byte
   ingress outcome, resize ingress, finish, one parsed description/encoded
   operation, and one public error path.  The byte ingress outcome already
   exists ("public facade decodes and renders output"); resize ingress and
   finish do not exist in the current file and must be authored as two new,
   compact `%expect_test`s distilled from the core-owned originals moved in
   step 8 (grid_test.ml's "session resize ingress is ordered, observable, and
   does not consume bytes" and "session finish flushes the final grapheme"),
   using a smaller fixture if that keeps the public suite compact — this step
   is not pure subtraction.  Do not duplicate the exhaustive Terminfo/encoder/
   repaint fixtures there.  Its Dune library continues to import `tessera`,
   never `tessera_foundation`, `tessera_model`, or any other internal
   package.

## Migration order

1. Add empty target stanzas, aliases, and the low-level support/fixture
   libraries.  Confirm they compile while the monolithic suites still run.
2. Extract independent component suites in dependency order: model, decoder
   plus corpus, renderer, then Terminfo, encoder, and repaint.  Run each
   target and compare the full `@runtest` output after every extraction.
3. Extract core and integration last, then trim the public facade suite to
   its smoke/compatibility role.  Delete `grid_test.ml` only after every test
   has a single destination and no Dune stanza references it.
4. Run `dune build @runtest`, every documented per-target alias, and `make
   precommit`.  Use `dune promote` only when an intentional, reviewed expect
   formatting change is unavoidable; it is not part of normal verification.
5. Update `.ai/terminal-todo.md` in the same commit, checking only the native
   expect-suite split item.  Leave the later property, fuzz, allocation,
   adapter, and integration-package items unchecked.

## Acceptance criteria

- No monolithic `grid_test.ml` remains; each test has one clear component,
  core, integration, corpus, or public-facade owner.
- The native component suites run independently, and their Dune dependency
  graph prevents decoder/renderer circular test coupling.
- A distinct fixture/corpus target contains named retained decoder fixtures
  and runs under the native test aggregate.
- The public-facade test is a distinct native inline-test target and imports
  only `Tessera`’s public surface.
- All existing expect assertions retain the same semantic coverage and stable
  output; no source behaviour or public API changes are introduced merely to
  facilitate the split.
- `make precommit` succeeds without modifying tracked files, and JSOO and
  Melange runtime-fixture build targets still succeed.
