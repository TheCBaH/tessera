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
| `test/web_rendering` | `@test-web-rendering` | `tessera_test_web_rendering` | `Web_frame.of_outcome`/`rows_of_cells`/`validate` (reset/delta, upgrade-to-reset, wide-glyph pairing, background/glyph invariants), `Web_html`/`Web_canvas` projections, `Web_json` envelope encode/decode goldens, and a QCheck properties executable (`validate` always holds, a reset frame matches its source snapshot via an independent projection-verifier, generation monotonicity) |
| `test/json_codec` | `@test-json-codec` | n/a (`corpus` executables in `upstream/`, `vendored/`) | The vendored, Melange-compatible `tessera_jsont`/`tessera_bytesrw`/`tessera_jsont_bytesrw` (`vendor/json_codec`) against the real opam `jsont`/`bytesrw`: a shared corpus module (including a real multi-byte UTF-8 grapheme, not just ASCII) compiled once per package family (native only, since both are `(wrapped false)` and cannot link into one executable) and diffed; the vendored corpus is also compiled to JSOO and Melange and executed with plain `node` (no `npm`), diffed against its own native output, so cross-runtime byte-identity is a real, executed check, not a compile-only one. Each printed line is hex-encoded before comparison, working around a real Melange `caml_io.js` stdout bug (a non-ASCII JS string code unit is re-encoded as UTF-8 text on write, inflating its byte count) documented in `corpus.ml`, unrelated to the codec's own (correct) encoded bytes |
| `test/web_rendering_codec` | `@test-web-rendering-codec` | n/a (`corpus` executable) | The same real, executed cross-runtime check as `test/json_codec`, but for `lib/web_rendering` itself: a single row is built by driving a real `Tessera_renderer` history (`Set_style`/`Print` updates, including a real multi-byte UTF-8 grapheme) through `Web_frame.of_outcome`, exercising every colour kind and rendition flag as they actually co-occur on a cell (not hand-assembled, so a background span's and its glyph's styles can never disagree the way a hand-built record could), then encoded to both HTML and Canvas JSON envelopes via `Web_json`, compiled natively/JSOO/Melange, executed with plain `node`, and diffed byte-for-byte (each line hex-encoded, same reason as `test/json_codec`). `@jsoo`/`@tessera-melange` (`make jsoo`/`make melange`) depend on this directory's js/melange artifacts, so those targets actually build and run `lib/web_rendering` under those backends rather than only the runtime-fixture smoke targets |
| `test/web_rendering_trace_fixture` | n/a (library) | `tessera_test_trace_fixture` | Portable (byte/native/melange) decoder for `test/node_pty/traces/*.json` *content* (no file I/O, so it also compiles under Melange); shared by `test/web_rendering_traces` and `test/web_bridge_equivalence` |
| `test/web_rendering_traces` | `@test-web-rendering-traces` | n/a (`replay` executable) | Native (no PTY, no Node) replay of the committed `test/node_pty/traces/*.json` real-terminal-output fixtures through `Tessera_js_adapter.Js_adapter` and `Web_frame.of_outcome`, encoding the final HTML/Canvas target-frame JSON via `Web_json` and diffing against `goldens/*.out`. Proves the web-rendering projection against real dialog/whiptail/shell output on every build, independent of whether `test/node_pty`'s JSOO/Melange PTY suite is built. See "Canonical real-terminal traces" below |
| `test/web_bridge_equivalence` | `@test-web-bridge-equivalence` | n/a (`corpus` executable) | The same real, executed cross-runtime check as `test/web_rendering_codec`, but for `lib/web_bridge`'s `push`/`resize`/`finish` surface: replays each of the six committed traces (embedded as string literals in `embedded_traces.ml`, since Melange has no file I/O) through the bridge for both targets, printing every emitted frame (not just the last -- see corpus.ml), compiled natively/JSOO/Melange, executed with plain `node`, diffed byte-for-byte. This is what surfaced a real Melange gap in the vendored `jsont`'s object *decode* path (see "Canonical real-terminal traces" below) -- `test/web_rendering_codec` only ever exercised encode |
| `test/web_bridge_runner` | n/a (library) | `tessera_test_web_bridge_runner` | Portable (`byte`/`native`/`melange`) wrapper around `Tessera_web_bridge.Web_bridge`, taking a `target` string so one wrapper serves both the HTML and Canvas targets; bakes the canonical create-then-resize bootstrap sequence into `create` so no caller can diverge from it. Shared by `test/web_render_playwright`'s browser backends and its native JSONL golden generator |
| `test/web_render_fixtures` | n/a (`gen_fixtures` executable) | n/a | Native-only generator for `test/web_render_playwright/fixtures/*.json`, a committed synthetic edge-case frame corpus (colours, every rendition class individually and combined, a coloured blank background, a combining grapheme, a wide glyph at a row boundary, cursor visible/invisible/pending-wrap, a reset-then-delta row replacement, a cursor-only delta, and a title-only delta) built by driving real `Tessera_renderer` histories, like `test/web_rendering_codec`'s corpus. An explicit developer command (`make web-render-gen-fixtures`); see "The browser driver and Playwright" below |
| `test/web_render_playwright` | n/a (Playwright + Node) | n/a | The browser driver, HTML target, and Playwright structural/screenshot suite; see "The browser driver and Playwright" below |
| `test/core` | `@test-core` | `tessera_test_core` | `Session.ingest`/`finish`, resize ordering/observation, retained sessions |
| `test/integration` | `@test-integration` | `tessera_test_integration` | Full `Patch → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply` round trip |
| `test/proxy_linux` | `@test-proxy-linux` | `tessera_test_proxy_linux` | Deterministic fake-platform proxy contract: byte-exact bidirectional relay, typed ingest failure ordering, observer records, resize and direct-renderer snapshot equivalence |
| `test/proxy_tmux` | `@test-proxy-tmux` | n/a | Detached fixed-size tmux compatibility cases for dialog, whiptail, custom VT redraw/form and resize fixtures; exact committed pane captures and installed emulator versions |
| `test/node_pty_bridge` + `test/node_pty` | `@test-jsoo-pty`, `@test-melange-pty` (opt-in; see below) | `tessera_test_node_pty_bridge` | A runtime/integration suite: the same dialog/whiptail/VT/resize/shell-session cases as `test/proxy_tmux`, driven through a real Linux PTY by the generated js_of_ocaml and Melange `tessera.js_adapter` builds via Node's `node-pty`, asserting Tessera's own logical-screen snapshot (not a visual emulator capture) against a committed golden |
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
and `test/renderer` cannot reach each other or `tessera` (core), and so on. `test/web_rendering`
follows the same rule: it depends on `tessera_renderer` directly (matching `lib/web_rendering`
itself), not the `tessera` facade -- gluing a real `Tessera.outcome` to `Web_frame.of_outcome` is a
future JS-bridge milestone's job, not this one's. `test/integration` and `test/public` depend only on the public `tessera` facade,
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

`test/node_pty_bridge` (library `tessera_test_node_pty_bridge`, module `Bridge`, `byte`/`melange`
modes) and `test/node_pty` are a runtime/integration complement to `test/js_adapter`:
where that suite proves `tessera.js_adapter` runs correctly as direct synchronous calls, this one
proves the same generated JSOO/Melange code runs a *real* Linux terminal program end to end.
`Bridge` owns constructing a `Js_adapter.t` with a fixed, generous xterm-256color policy (mirroring
`lib/proxy_linux/proxy.ml`'s own built-in policy, for the same reason: a real interactive program,
not a synthetic fixture, drives what crosses this boundary), the `push`/`resize`/`finish` calls, and
a stable text rendering of the latest logical screen (fixed `columns`x`rows`, active screen, cursor,
title, and diagnostics) for golden comparison -- every entry point takes and returns only
`int`/`string`, so it compiles unchanged for both backends. `test/node_pty/jsoo_runner.ml` and
`melange_runner.ml` are the only backend-specific code (an explicit `Js.export` shim for jsoo;
Melange needs none beyond the re-export, since a Melange function already compiles straight to a
CommonJS export of the same name and arity). `test/node_pty/run.js`, shared by both backends, owns
the actual Linux PTY boundary via the locked `node-pty` npm package: it spawns the ported
`test/proxy_tmux` cases (`dialog`/`whiptail`/VT redraw/form/resize/shell-session) directly under a
PTY (no tmux layer in this suite -- Tessera's own snapshot is the oracle, not a second terminal
emulator's pane capture), drives them via `test/node_pty/fixture.sh` (`test/proxy_tmux/fixture.sh`
ported to file-based ready/done/captured signalling, since there is no tmux `wait-for` channel here),
and asserts both the fixture's own result and a `test/node_pty/goldens/*.txt` snapshot golden. This
suite is what caught a real, previously untested bug: `lib/model/unicode.ml`'s width function used
Unicode's raw `Emoji` property, which is set on plain ASCII digits/`#`/`*` (they are the keycap
emoji sequences' base character) even though they render as ordinary narrow text on their own --
`Emoji_Presentation` is the property that reflects default rendered width; see
`test/model/unicode.ml`'s `"grapheme width distinguishes Emoji from Emoji_Presentation"` case.

This suite needs a Node runtime and the locked node-pty workspace (`make node-pty-install`, i.e.
`cd test/node_pty && npm ci`), so `@test-jsoo-pty`/`@test-melange-pty` (`make test-jsoo-pty` /
`make test-melange-pty` / `make test-node-pty`) stay separate Make/dune targets rather than folding
into `@runtest`/`make test`, so a normal OCaml-only build never needs Node. `.github/workflows/build.yml`
runs `make node-pty-install` (cached across runs by `test/node_pty/package-lock.json`'s hash, since
`npm ci` recompiles node-pty's native addon from source) and `make test-node-pty` as explicit CI steps.

### Canonical real-terminal traces

`test/node_pty/run.js`'s `TESSERA_NODE_PTY_WRITE_TRACES=1` environment variable (`make
node-pty-capture-traces`) is an opt-in developer command, independent of the `TESSERA_NODE_PTY_WRITE_GOLDENS`
snapshot-golden regeneration above: it additionally records the ordered `data`/`resize` events each
of the six cases actually produced -- coalescing `data` at control-event (resize) boundaries, since
node-pty's own OS-dependent read chunking is not a semantic protocol worth pinning -- and commits them
to `test/node_pty/traces/<name>.json` (initial geometry, base64-encoded byte spans, explicit resize
events, cut off at the same OSC completion-sentinel boundary `snapshotText` already waits for, so
child-exit/cleanup noise never leaks into the fixture). Like any other golden regeneration, review the
diff before committing.

`test/web_rendering_traces` then replays those committed traces natively -- no PTY, no Node, no
js_of_ocaml/Melange runtime -- through the same `Tessera_js_adapter.Js_adapter` push/resize/finish
surface the capturing bridge used (with `test/node_pty_bridge/bridge.ml`'s own fixed, generous
policy, since that is what actually produced the committed traces), projects the final outcome
through `Web_frame.of_outcome`/`Web_json`, and diffs the resulting HTML/Canvas target-frame JSON
against `test/web_rendering_traces/goldens/*.out`. Unlike `@test-jsoo-pty`/`@test-melange-pty`, this
replay is part of `@runtest`/`make test`: it validates the web-rendering projection against real
dialog/whiptail/shell output on every ordinary OCaml-only build, without needing Node at all.

### `lib/web_bridge` and the JSOO/Melange equivalence check

`lib/web_bridge` (`Tessera_web_bridge.Web_bridge`, `byte`/`native`/`melange` modes) is
the boundary bridge made real: one thin `create`/`push`/`resize`/`finish`
surface that does the whole pipeline per call (`Js_adapter` ingest, `Web_frame.of_outcome`, a
`target`-selected `Web_html`/`Web_canvas` projection, `Web_json` encode) and returns the canonical JSON
string directly. Its target (`Html`/`Canvas`) is fixed for a bridge's whole lifetime, matching how a
browser page mounts exactly one target. It has no `js_of_ocaml`/Melange-specific type in its signature,
so (like `Tessera_js_adapter.Js_adapter`) it compiles unchanged under all three modes; a real browser
integration's only backend-specific code is a thin `Js.export`/re-export shim per backend, mirroring
`test/node_pty/jsoo_runner.ml`/`melange_runner.ml` -- see `test/web_bridge_runner` and
`test/web_render_playwright`'s `jsoo_bridge.ml`/`melange_bridge.ml`, the browser driver
that actually calls it, described below.

`test/web_bridge_equivalence` proves this bridge is byte-identical across backends: it replays the same
six committed traces (embedded as string literals in `embedded_traces.ml`, generated once from
`test/node_pty/traces/*.json` and committed like `lib/terminfo/bundled.ml`'s own checked-in data,
since Melange has no file I/O) through `Web_bridge` for both targets, printing every emitted frame, and
diffs native/JSOO/Melange output byte-for-byte -- the same `test/web_rendering_codec`-style corpus
pattern, but exercising the bridge's actual `push`/`resize`/`finish` calls (and, unlike
`test/web_rendering_codec`, JSON *decode*, not just encode: `Trace_fixture.of_string` decodes the
embedded fixture JSON before replay).

That decode call is what surfaced a real, previously-undiscovered Melange gap in the vendored `jsont`
(`vendor/json_codec/patches/jsont_base.ml.patch`): `Jsont`'s internal `Type.Id.uid` (used only as a
`Dict` lookup key by `Jsont.Object.mem`'s machinery) derived its result from
`Obj.Extension_constructor.id (Obj.Extension_constructor.of_val ...)`, which raises under Melange's
`Obj`. `test/web_rendering_codec`'s corpus never decoded a JSON object under Melange, only encoded one,
so this had never been exercised. The patch replaces `uid` with a plain monotonic counter stamped into
the generated module at `Type.Id.make` time -- safe because every lookup is confirmed by
`provably_equal`'s GADT match before being trusted, so `uid` only needs to be distinct per `make` call,
not derived from any particular runtime representation. `Web_json.decode_html_frame`/`decode_canvas_frame`
were exposed to the exact same gap (untested under Melange until now); this patch fixes them too.

### The browser driver and Playwright

The shared browser driver, the plain-HTML target, and Playwright
structural/screenshot tests live in two places: `web/` at the repository root (shipped,
framework-free browser assets, loaded by a real page via plain `<script>` tags, no bundler) and
`test/web_render_playwright/` (the Playwright workspace and browser-loadable OCaml backends that
drive them in tests).

`web/tessera-decode.js` is the JS-side trust boundary: `decodeHtmlEnvelope` mirrors, rather than
solely implements, the exact structural contract `lib/web_rendering/web_json.ml`'s
`html_envelope_jsont`/`meta_jsont` already enforce -- schema/version/target, geometry agreement, row
uniqueness/range, background tiling and glyph non-overlap (walked in wire order, not sorted, matching
the OCaml decoder exactly), reset completeness, cursor bounds, and the canonical
non-negative-decimal syntax `^(0|[1-9][0-9]*)$` `generation`/`lineage_id` must match -- the same
closed `fg`/`bg`/class set `Web_html.valid_color_value`/`valid_class` accept, duplicated here
deliberately for a payload that, in a future transport, may not come from a trusted same-process
OCaml call. `web/tessera-trace-decoder.js` is the JS-side inverse of `test/node_pty/run.js`'s trace
capture: `decodeTraceBytes` turns a trace event's base64 `data` span back into the same kind of JS
string `node-pty`'s own `data` event hands to a bridge's `push`.

`web/tessera-driver.js`'s `TesseraDriver` is the rollback-safe *and* recoverable resync state
machine: `{lineageId, generation, awaitingReset}`
tracked as `BigInt` (never JS `number`, which cannot represent every value a wire integer can), fenced
at both the generation level (a stale or duplicate generation is dropped unconditionally, *including*
a stale reset -- a full-content reset is still rejected if older than what's already painted) and the
lineage level (a lineage no newer than the tracked one is dropped unconditionally, regardless of
frame kind -- the defence against a delayed reset from a retired lineage rolling the DOM back after
recovery). It also tracks the `meta.geometry`/`meta.active` established by the last accepted `reset`
and rejects any `delta` claiming either one changed -- `Web_frame.of_outcome` always upgrades a resize
or active-screen switch to a `reset` (`lib/web_rendering/web_frame.ml`), so a `delta` disagreeing with
the tracked geometry/screen is a protocol violation, not a smaller update; the driver drops it,
requests resync, and never draws it onto the old grid/screen. The only supported recovery from a
detected gap is a `reset` under a new, strictly greater lineage id; there is no in-band "resend
generation N" request. The driver only dispatches to a `target` implementing
`mount`/`reset`/`draw`/`setMetrics`/`dispose` -- no DOM/terminal logic lives in the driver itself,
which is what makes `test/web_render_playwright/tests/driver.node.test.js` (plain `node --test`, no
browser) possible: it drives the full resync state machine, including the gap-then-new-lineage
recovery sequence, rejection of a delayed reset from a retired lineage after that recovery, and
rejection of a geometry- or active-screen-changing delta, against a fake `target` that only records
calls. `document.title` is set from
`meta.title` on every accepted `reset`/`draw`, guarded by `typeof document !== 'undefined'` so the
driver stays usable in that Node-only test.

`web/tessera-html-target.js`'s `TesseraHtmlTarget` builds DOM nodes from `Web_html.t`'s structured
frame data via `createElement`/`className`/`style.setProperty`/`textContent` only -- never
`innerHTML`, so no HTML-escaping logic is needed on the JS side at all -- matching
`lib/web_rendering/web_html.ml`'s `add_row`/`add_background`/`add_glyph`/`add_cursor` exactly (same
classes, `data-*` attributes, CSS custom-property colours, and explicit grid placement). `reset`
clears every tracked row, including any DOM node left over from a larger prior geometry; `draw`
replaces only the named rows plus the cursor, never touching an untouched row's DOM node (asserted by
identity, not just content, in the Playwright specs). `probe()` is test-only: it reconstructs
`{columns, row_count, rows, cursor}` by reading back the live DOM, the oracle every structural
assertion in `test/web_render_playwright` compares against. `web/tessera.css` is the separately
versioned stylesheet: `.tessera-frame` is a real CSS Grid sized from `--tessera-columns`/`-rows`;
`.tessera-row` spans every real column before `grid-template-columns: subgrid` lets its own children
place via their own inline `grid-column`; the full 256-colour xterm palette is committed as static
`--tessera-color-0`..`-255` custom properties. `setMetrics`'s `cellWidth`/`cellHeight`/`lineHeight`
are stored with an explicit `px` unit (a bare unitless number in a `<length>` custom-property
position is invalid CSS and silently collapses the whole grid track list to nothing -- caught by an
actual screenshot test, not by any DOM-structure assertion, which is exactly why a screenshot oracle
is required and not merely a nice-to-have).

`test/web_bridge_runner` (`byte`/`native`/`melange`) wraps `Tessera_web_bridge.Web_bridge` behind a
`target:string -> lineage_id:int -> columns:int -> rows:int -> string` `create`, baking the
canonical create-then-resize bootstrap sequence into itself (mirroring
`test/node_pty_bridge/bridge.ml`/`test/web_rendering_traces/replay.ml`'s own "create then an explicit
initial resize" sequence) so the native golden generator and every browser backend share one
implementation and cannot silently diverge. `test/web_render_playwright/jsoo_bridge.ml` and
`melange_bridge.ml` are the thin backend-specific export shims around it, mirroring
`test/node_pty/jsoo_runner.ml`/`melange_runner.ml`; the Melange side compiles via a *new*
`(module_systems (esm mjs))` `melange.emit` stanza (confirmed against this repository's installed
dune 3.24.2 binary, distinct from `test/node_pty/dune`'s existing `(module_systems commonjs)`, which
stays untouched), emitting real ES modules loadable via a browser's native `import()` -- no bundler.

Because dune's Melange ESM output uses bare package-name specifiers for any *installed* library
(`import ... from "tessera.foundation/limits.mjs"`, mirroring the `node_modules/<package>/...`
directory tree dune also emits inside the target), and a browser's native module loader accepts only
relative/absolute URL specifiers, `test/web_render_playwright/server.js` (a plain Node `http` static
server, no Express, no bundler) generates a `<script type="importmap">` from that emitted
`node_modules` directory listing and injects it into `pages/index.html` before any other script --
the standard, declarative, non-bundling way to teach a browser the same mapping dune's directory
layout already encodes. Modules belonging to the project itself (no `public_name`, e.g.
`bridge_runner.mjs`, `melange_bridge.mjs`) already use plain relative imports and need no map entry.
`pages/index.html`'s `window.TesseraBackends.load('jsoo' | 'melange')` is the backend selector every
Playwright spec uses; a dedicated smoke test (`tests/smoke.spec.js`) loads each backend and proves
`create`/`push`/`resize`/`finish` are callable with their documented arguments before any replay test
depends on them (a bare `typeof` check would miss an under/over-curried export -- jsoo's exported-
function wrapper and Melange's `unit -> 'a` representation both report misleading JS `Function.length`
values, so the smoke test instead calls each with its real argument count and checks the result
decodes).

`test/web_render_fixtures/gen_fixtures.ml` (native only, `make web-render-gen-fixtures`) commits the
synthetic edge-case frame corpus (`test/web_render_playwright/fixtures/*.json`) that
`tests/fixtures.spec.js` loads directly, bypassing the bridge/trace machinery entirely -- proving the
DOM/CSS mapping and `document.title` updates in isolation, including the round-trip-tricky cases (a
coloured blank background via `Erase`, not a printed space; a reset-then-delta that replaces one full
row while leaving another untouched; a delta that only moves the cursor; a reset-then-delta that
changes only the title, isolating that path from row/cursor updates, since neither `probe()` nor a
screenshot can observe `document.title`).

`test/web_render_playwright/gen_goldens.ml` (native only, `make web-render-gen-goldens`) generates
`goldens/<case>-html.frames.jsonl`: every frame `test/web_bridge_runner`'s canonical sequence emits
for each of the six committed `test/node_pty/traces/*.json` cases (`lineage_id:1`, one session per
case), one JSON line per frame, in order. `tests/web_render.spec.js` replays the same six traces
through both backends and checks **two independent oracles for two distinct properties** (a JSONL
golden's last line is `finish()`'s own small delta and cannot be deep-equal to a full reconstructed
DOM): the captured ordered frame sequence against this JSONL golden (wire-stream fidelity), and
`probe()`'s fully-reconstructed DOM against the *existing* `test/web_rendering_traces/goldens/
<case>.out` file's `html:` line -- an independent full reset built straight from the final terminal
snapshot, never derived from the JSONL sequence -- including `document.title` against that same
golden's `meta.title`. Then a final-state screenshot per case x backend, plus mid-replay checkpoint
screenshots for the jsoo backend on `vt-resize-redraw`/`vt-scroll-redraw`/`vt-form-edit` (cross-backend
equivalence for those intermediate frames is already proven structurally by
`test/web_bridge_equivalence`'s every-frame assertion, so it is not duplicated per backend here).

`tests/html_target_dom.node.test.js` (plain `node --test`, no browser, no jsoo/Melange build) is a
faster, narrower mirror of `web_render.spec.js`'s "final DOM state matches the native replay golden"
check: it feeds each committed `goldens/<case>-html.frames.jsonl` straight into a real `TesseraDriver`
+ `TesseraHtmlTarget` running under `jsdom` (a headless, Node-only DOM implementation -- pinned to
`25.0.1`, the latest release still supporting this project's Node 20 baseline; a newer major fails to
even load here, since it depends on `undici` internals only present on Node >=22) and compares
`probe()` against the same `test/web_rendering_traces/goldens/<case>.out` `html:` line oracle, with no
Chromium and no bridge build in the loop -- a fast, DOM-construction-only failure signal. It
deliberately does *not* replace `web_render.spec.js`'s own version of this check: only the real browser
suite proves wire-stream fidelity per backend (jsoo/Melange), real CSS Grid layout, and the screenshot
oracle, none of which `jsdom` can stand in for.

The loopback HTTP/WebSocket server is deliberately native/Lwt/Unix code, so the live-proxy tests exercise
one native producer only; they cannot be made into one end-to-end server test per generated backend. The
portable rendering path is instead covered per backend by `web_render.spec.js` and
`test/web_bridge_equivalence`: both execute the JSOO and Melange producers and compare their complete
frame streams and reconstructed DOM against the native trace oracle. Together, the layers prove native
transport/authentication/reconnect separately from JSOO/Melange rendering parity.

This suite needs a Node runtime, the locked npm workspace, and a pinned Chromium install
(`make playwright-install`, i.e. `cd test/web_render_playwright && npm ci && ./node_modules/.bin/
playwright install chromium`), so `make test-web-render` stays a separate target from `@runtest`/
`make test`/`make check`, like `make test-node-pty`. It runs `tests/*.node.test.js` first (fastest, no
browser), then builds the jsoo/Melange browser artifacts, then the full Playwright matrix.
`.github/workflows/build.yml` runs it with two independent caches -- one for `node_modules` (keyed by
this workspace's own `package-lock.json` hash) and one for Playwright's browser download directory
(keyed by OS/architecture plus the locked `@playwright/test` version, so a version bump invalidates it
on its own) -- mirroring, but not sharing, the `node-pty` cache above.

Screenshot tests run one pinned Chromium version (the locked `@playwright/test` binary,
`./node_modules/.bin/playwright install chromium`) in this project's devcontainer/CI image, with the
vendored `@fontsource/jetbrains-mono` font, a fixed viewport, `deviceScaleFactor: 1`, and animations
disabled (`playwright.config.js`). Baselines are committed from that same environment; browser/font
variation is expected, and baseline regeneration outside it is not accepted -- refresh them
deliberately with `make playwright-update-screenshots` (like `test/proxy_tmux/regenerate_goldens.sh`,
never run in CI) and review the diff before committing.

## Running one layer

```
dune build @test-decoder
dune build @test-renderer
dune build @test-decoder-corpus
dune build @test-fuzz
```

`dune runtest` / `make test` / `make precommit` run everything.

To deliberately refresh the headless tmux pane captures after a reviewed
compatibility change, run:

```
test/proxy_tmux/regenerate_goldens.sh
```

The script changes checked-in golden files but never runs in CI; review and
commit those changes explicitly. `make precommit` rejects an unexpected dirty
worktree.
