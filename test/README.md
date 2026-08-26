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
| `test/proxy_linux` | `@test-proxy-linux` | `tessera_test_proxy_linux` | Deterministic fake-platform proxy contract: byte-exact bidirectional relay, typed ingest failure ordering, observer records, resize and direct-renderer snapshot equivalence |
| `test/proxy_tmux` | `@test-proxy-tmux` | n/a | Detached fixed-size tmux compatibility cases for dialog, whiptail, custom VT redraw/form and resize fixtures; reports installed emulator versions |
| `test/public` | `@test-public` | `tessera_test_public` | Public `Tessera` facade smoke/compatibility examples only |
| `test/properties` | `@test-properties` | n/a (`properties` test executable) | QCheck properties: arbitrary decoder chunking, resize/byte ingress interleavings, same-size resize refresh, checkpoint replay/branching, patch algebra, renderer invariants, source/compiled Terminfo equivalence |
| `test/fuzz` | `@test-fuzz` | n/a (`decoder_fuzz`/`terminfo_fuzz` Crowbar executables) | Native fuzzing under small policy limits: decoder never raises on arbitrary/chunked bytes or oversized malformed control strings; compiled/source Terminfo parsing never raises on arbitrary or structurally-plausible bytes |
| `test/memtrace` | `@test-memtrace` | n/a (`benchmark` executable, build-only) | Native release benchmark workload; run with `MEMTRACE=<file>` to capture an allocation trace for manual inspection |
| `test/conformance` | `@test-conformance` | `tessera_test_conformance` | Reusable adapter-conformance fixture: ordered ingress, short writes, backpressure, EOF, failures, observer-gap/authoritative-snapshot resynchronisation, and distinct/equal-size/coalesced resize events, replayed against a reference driver |
| `test/unix_adapter` | `@test-unix-adapter` | `tessera_test_unix_adapter` | Replays `test/conformance`'s fixture against the real `lib/unix_adapter` (`tessera_unix`) reading from an OS pipe on a background thread; negative resize input and a real read failure |
| `test/lwt_adapter` | `@test-lwt-adapter` | `tessera_test_lwt_adapter` | Replays `test/conformance`'s fixture against the real `lib/lwt_adapter` (`tessera_lwt`) reading from an OS pipe on the Lwt event loop; negative resize input and a real read failure |
| `test/async_adapter` | `@test-async-adapter` | `tessera_test_async_adapter` | Replays `test/conformance`'s fixture against the real `lib/async_adapter` (`tessera_async`) reading from an OS pipe via `Async.Reader`; negative resize input and a real read failure |
| `test/js_adapter` | `@test-js-adapter` | `tessera_test_js_adapter` | Replays `test/conformance`'s fixture against the real `lib/js_adapter` (`tessera.js_adapter`, the JSOO/Melange adapter) as direct synchronous calls; negative resize input |

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
`Renderer`/`Patch` values as a convention.

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

`test/conformance` depends only on the public `tessera` facade, like `test/integration` and
`test/public`, so a scheduler adapter package (section 6: Unix, Lwt, Async, JSOO, Melange) can
depend on it too. `test/conformance/scenario.ml` is the fixture itself: a scheduler-independent
`host_event` vocabulary (writes, short writes, backpressure markers, resize, coalesced resize,
failure, EOF) and the named scripted scenarios built from it. `test/conformance/reference.ml` is a
minimal synchronous driver serialising those events into `Tessera.ingest`/`finish` calls, used both
as this milestone's proof that the fixture is meaningful and as the oracle other adapters' drivers
are compared against.

`lib/unix_adapter` (package `tessera_unix`, library `Tessera_unix.Unix_adapter`) is the first such
adapter: a blocking `Unix.file_descr` read loop plus a thread-safe `resize` entry point, serialised
against the shared `Tessera.session` through an internal mutex that is held only around the brief
session mutation, never around the blocking read itself, so a concurrent resize is never stuck
behind a read that has not returned. `test/unix_adapter` depends on `tessera_test_conformance`
directly and replays `Scenario.all` (ordered ingress, short writes, and distinct/equal-size/
coalesced resize) against the real adapter reading from an `Unix.pipe` on a background `Thread`,
checking its final rendered content against `Reference.run`'s. `Backpressure_pause`/`resume` carry
nothing to deliver on a real descriptor and `Failure` isn't meaningfully reproducible on a plain
pipe, so those two are instead covered directly: a negative resize count and a read on a closed
descriptor are both asserted to come back as a typed error, never an exception.

`lib/lwt_adapter` (package `tessera_lwt`, library `Tessera_lwt.Lwt_adapter`) is the second adapter:
the same design as `tessera_unix` with Lwt's cooperative promises in place of OS threads, an
`Lwt_unix.file_descr` read loop, and an `Lwt_mutex.t` (instead of `Mutex.t`) held only around the
brief session mutation, never around the pending `Lwt_unix.read` itself, so a concurrent `resize`
promise is never stuck behind a read that has not resolved. `test/lwt_adapter` mirrors
`test/unix_adapter` exactly -- same scenarios, same two direct error cases -- but drives the reader
and the writer/resize events as concurrent promises on one `Lwt_main.run` call over an
`Lwt_unix.pipe` instead of a background thread. The read-failure fixture differs only in which libc
call reports `EBADF` first: `Lwt_unix.read` calls `set_nonblock` on the descriptor before the read
itself, so the closed-descriptor case is reported as `read-failed(set_nonblock(): ...)` rather than
`read-failed(read(): ...)`.

`lib/async_adapter` (package `tessera_async`, library `Tessera_async.Async_adapter`) is the third
adapter: the same design again, this time with Jane Street's Async scheduler. An
`Async.Throttle.Sequencer.t` (a one-job-at-a-time throttle, Async's equivalent of a mutex) replaces
`Mutex.t`/`Lwt_mutex.t`, held only around the brief session mutation, never around the pending
`Async.Reader.read` itself. The caller creates and owns the `Async.Reader.t` (and the `Async.Fd.t`/
`Fd.Kind.t` it wraps); the adapter only reads from it, mirroring how the other two take a raw
descriptor rather than owning one. Because `Async.Reader.read` can send an exception to the ambient
monitor instead of returning it, `read_step` wraps the read in `Async.Monitor.try_with` so a read
failure comes back as a typed `` `Read_failed of exn `` rather than crashing the scheduler.
`test/async_adapter` mirrors `test/unix_adapter`/`test/lwt_adapter`, driving the reader loop and the
writer/resize events inside one `Async.Thread_safe.block_on_async_exn` call over a plain
`Unix.pipe` (wrapped in an `Async.Fd.t`/`Async.Reader.t` on the read end only; the write end stays a
bare descriptor written with blocking `Unix.write_substring`, as in `test/unix_adapter`). The
read-failure fixture checks only the error's shape (`` `Read_failed _ ``), not its rendered text,
because that text embeds `Async.Reader.t`'s sexp -- including the raw OS file-descriptor number,
which is not deterministic across runs.

`lib/js_adapter` (library `tessera.js_adapter`, module `Tessera_js_adapter.Js_adapter`) covers the
remaining two section 6 adapter items, JSOO and Melange, with a single implementation: unlike the
three descriptor-reading adapters, a JS host has no OS descriptor to read and no scheduler-level
concurrency to guard with a lock, so `push`/`resize`/`finish` are plain synchronous functions that
return their outcome directly rather than delivering it through a callback -- the host's own event
handler (a Node stream's `"data"`/`"close"`, a WebSocket's `onmessage`/`onclose`, an xterm.js data
callback, ...) is the entire integration, with no `run` loop for this adapter to own. Because it has
no backend-specific code at all (no js_of_ocaml `Js.t` bindings, no Melange `external`s), it builds
in `byte` mode (consumed by a JSOO host exactly as `tessera_runtime_fixture` already is by
`js_smoke.ml`) and in `melange` mode directly, satisfying both checklist items the way the portable
core itself already does. `test/js_adapter` replays `test/conformance`'s fixture as direct
synchronous calls (no pipe, no thread, no scheduler); `Backpressure_pause`/`resume` and `Failure`
contribute no events, since a function-call interface has nothing to pause and no I/O layer that can
fail beyond the same typed validation `resize` always has. `test/runtime_fixture.ml`'s
`run_js_adapter` additionally exercises `push`/`resize`/`finish` end-to-end under `js_smoke.ml` and
`melange_smoke.ml`, so the adapter's portability (not just the core's) is proved on all three
targets, not merely compiled.

## Running one layer

```
dune build @test-decoder
dune build @test-renderer
dune build @test-decoder-corpus
dune build @test-fuzz
```

`dune runtest` / `make test` / `make precommit` run everything.
