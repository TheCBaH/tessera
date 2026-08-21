# Tessera: high-level implementation plan

## Goal and boundaries

Build a platform-independent, purely functional OCaml terminal-protocol library plus a Linux transparent proxy. The core decodes application output, applies shared semantic updates to immutable logical terminal state, and encodes updates for a declared terminal description. It owns no PTY, filesystem, clock, UI, or mutable terminal state. The proxy relays original bytes unchanged, maintains an observational state projection, and exposes it out of band.

The initial behavioural family is the documented xterm-256color subset in terminal-idea.md. Unsupported extensions must be framed safely, reported in bounded diagnostics, and forwarded unchanged; they must not silently change the logical screen.

The project is named Tessera: its opam/Dune package is `tessera`, its OCaml namespace is `Tessera`, and its Linux proxy executable is `tessera-proxy`.

The project and dependency boundaries are compared with existing terminal applications and libraries in [terminal-other.md](terminal-other.md).  That review is a design input, not a runtime dependency list.

## Package layout and dependency direction

Create a new tessera/ Dune package rather than adding terminal concerns to the FlatBuffers runtime. The core packages are portable to native OCaml, js_of_ocaml, and Melange. Only the proxy package is Unix/Linux-specific.

    tessera-model: common immutable types, policy, errors, Unicode tables
      ├─ tessera-terminfo: pure terminfo parsers and descriptions
      ├─ tessera-decoder: incremental bytes to updates and observations
      ├─ tessera-renderer: updates plus state to state, damage, and snapshots
      └─ tessera-encoder: updates plus description to bytes

    tessera-checkpoint: portable checkpoint values/codecs
      ├─ tessera-decoder (serialised continuation)
      └─ tessera-renderer (serialised renderer state; snapshots derive from it)

    tessera-repaint: controlled render target plus patch-to-update compiler
      ├─ tessera-renderer (Patch and snapshot projection)
      └─ tessera-terminfo / tessera-encoder (capability selection and bytes)

    tessera-proxy-protocol: observer schema and FlatBuffers codec
    tessera-proxy-linux: PTY, process, discovery, relay, and socket server

tessera-model must not depend on any other terminal layer. In particular, the decoder only emits operations and requests; it never reads renderer state. The renderer does not know byte syntax, the encoder does not apply updates, and the terminfo parser does not discover files. The proxy is the composition root and the only layer permitted to use operating-system I/O.

Use wrapped libraries under a public Tessera namespace and one module per stable domain concept. Keep parser automata and persistent-grid implementation types private behind mli files. Public variants are written in alphabetical constructor order, and public record fields in alphabetical field-name order, except where a referenced external wire format fixes an order. This is a source/API convention, not a claim that variant order carries protocol meaning.

## Data types by module

| Module | Main types | Purpose |
| --- | --- | --- |
| Tessera.UInt | t = private int | Tessera-owned portable non-negative, checked machine integer for bounded counts, indexes, and dimensions. It is deliberately not an OCaml Stdlib module or a machine-unsigned integer: that concept is not portable to JSOO/Melange. |
| Tessera.Byte_offset | t | Non-negative, checked 64-bit stream position. It wraps the `Int64` representation so an offset cannot be confused with a count or identifier. |
| Tessera.Id | `'kind t = private int` | Generic phantom-typed opaque identifier over a checked portable `int`. `equal`/`compare` require the same phantom kind, preventing accidental comparison of unlike IDs. |
| Tessera.Generation | `type t = Generation.tag Id.t` | Monotonically increasing logical-state version. It is a typed revision token, not a globally unique ID and not a raw `int64`; exhaustion starts a new lineage rather than wrapping. |
| Tessera.Line_id | `type t = Line_id.tag Id.t` | Typed logical-line identity; unique within one renderer state lineage. It uses a checked portable `int` and never wraps silently. |
| Tessera.Lineage_id | `type t = Lineage_id.tag Id.t` | Adapter-supplied identity for a renderer lineage. Patches carry it so generation equality cannot accidentally bridge independent lineages. |
| Tessera.Types | column; coord; direction = Application_to_terminal or Terminal_to_application; rect; row; screen = Alternate or Primary; size | Validated geometry wrappers. Columns/rows and sizes are positive where required; coordinates and counts use the relevant `UInt` wrapper. |
| Tessera.Unicode | scalar; opaque grapheme sequence; width = One, Two, or Zero; utf8_error | Incremental UTF-8 and pinned Unicode 15.1 grapheme/display-width rules. Tables are generated and checked in. |
| Tessera.Style | attributes; color = Default, Indexed, or Rgb; hyperlink_id; style; validated palette/RGB values | SGR style, indexed/RGB colour, underline variants, protection, and OSC 8 link metadata. |
| Tessera.Cell | contents = Attachment, Empty, Glyph, or Wide_continuation; cell = contents, flags, line_id, style | Physical display cell. A wide glyph has a lead plus continuation cell; attachments have stable placeholder layout. |
| Tessera.Provenance | layout_anchor; line_break = Hard or Soft_wrap; line_id; logical_line | Logical-line identity and enough text/attachment provenance for later reflow, while release one remains no-reflow. |
| Tessera.Mode | Closed records/variants for insert, origin, auto-wrap, cursor visibility, mouse, focus, bracketed paste, character sets, margins, and tabs | Typed presentation and addressing state; never stringly named flags. |
| Tessera.Effect | request: capture, clipboard, device/status query, hyperlink, notification, title; observation: diagnostic, reply, resource event, unsupported extension | External behaviours as data only. Embeddings, not the core, perform effects. |
| Tessera.Update | Alphabetically ordered operation variants; `Batch.t` | The one ordered semantic language shared by decoder, renderer, and encoder. The abstract batch is an ordered sequence, never a set or map. |
| Tessera.Collection | Cell_blocks, Damage, Snapshot_cells, and Tab_stops | Abstract canonical geometry/set collections. Ordered sequences live with their domain (`Update.Batch`, `Effect.*_sequence`, and `Unicode.Grapheme_sequence`); capability maps live in Description. |
| Tessera.Repaint | target; compile; local `error` domain | Optional controlled-output layer: checks a known render target against a patch generation, lowers absolute changes to ordered updates, then passes them to Encoder. It is not used by the transparent proxy. |
| Tessera.Policy | compatibility; effect_policy; limits; policy; unicode_policy | Validated finite bounds for pending strings, diagnostics, history, attachments, snapshots, decompression, and selected family. |
| Tessera.Description | family = Xterm_256color; feature; capability; capability_program; description | Parsed terminfo capability data plus explicit behavioural-family compatibility. |
| Per-module `Error` domains | Local polymorphic-variant payloads, `pp_error`, and an `Err.Make` binding | There is no global error registry. Components expose only the error vocabulary relevant to their own contract; composition layers define explicit variant unions. |

An update batch is ordered and is always applied left to right. Its constructors carry operations, not precomputed state-dependent outcomes. The renderer determines defined clamping/no-op behaviour and policy rejection against the supplied state.

## Update batches and composable patches

The architecture uses two related immutable languages:

1. `Tessera.Update` is the decoder's ordered terminal-operation language. It preserves protocol meaning: cursor movement, wrapping, scrolling, margins, and styles are interpreted only by the renderer against a state. `Update.Batch.normalize` performs only sequence-safe rewrites, such as merging adjacent printable graphemes and composing adjacent style/mode deltas. It never rewrites state-dependent operations such as scroll, insert/delete, or cursor-relative movement.
2. `Tessera.Patch` is the renderer's absolute, state-independent output language. It describes the resulting projection as physical cell replacements at absolute coordinates, presentation-field changes, damage, and ordered observations. A scrolling operation therefore becomes replacements for the affected physical region in this first implementation, not a symbolic scroll command.

`Patch.compose left right` requires equal `Lineage_id.t` values and `left.after_generation = right.before_generation`. `Generation.t` is a monotonic revision token: it identifies a required predecessor state within that lineage, but is neither a globally unique ID nor a raw numeric API. Composition then performs a last-writer-wins overlay of cell replacements and presentation fields. It emits canonical row-major runs, merging adjacent compatible cells into rectangles where possible. A later resize is a composition barrier: prior cell replacements are discarded and the later patch supplies replacements in the new geometry. Observations retain order and are never cancelled.

This makes patch composition depend only on two patches and their generation/geometry metadata, never on a renderer state. It can eliminate overwritten writes and compose a succession of one-cell replacements into compact row runs or rectangles. It deliberately remains conservative: a terminal operation may be dropped only when its algebra proves the rewrite valid without knowing the input state. The raw update batch remains the source of terminal semantics; a patch is the composable projection sent to observers.

### Collection semantics and canonical ordering

Do not expose a bare `list`, `array`, `set`, or `map` in the public semantic API when its law is important. Each public collection gets an abstract module and explicit constructors/enumerators:

| Collection | Required law and representation choice | Combination rule |
| --- | --- | --- |
| `Update.Batch.t` | Ordered finite sequence; duplicates are valid and every item can affect the next. Internally it may be built as a reverse list and frozen as an array/vector, but that is private. | Concatenation is left-then-right. `normalize` only applies proven sequence-preserving rewrites. |
| `Effect.Item_sequence.t` and `Observation_sequence.t` | Ordered finite sequence, including repeated diagnostics/replies. A set/map would lose causal order. | Concatenation is left-then-right; observations are never cancelled by a later item. |
| `Patch.Cell_blocks.t` | Canonical finite collection of disjoint, sorted blocks keyed by screen/row/column. It is not an operation sequence after normalisation. | Later patch wins at overlapping cells; normalize rejects/repairs overlaps and emits canonical blocks. |
| `Damage.t` | Canonical set of covered rectangles rather than an ordered history. | Union then normalize/merge; it is idempotent and order-insensitive. |
| `Tab_stops.t` | Finite set of columns in one buffer. | Set/add/remove are idempotent; enumeration is increasing column order. |
| `Description.Capability_map.t` | Map because every capability key has one value and lookup is primary. | Merge has explicit `use=` precedence and reports incompatible duplicate types. |

All exposed enumeration functions return a canonical order. That makes printers, checkpoints, FlatBuffers conversion, and expect tests deterministic without suggesting that a semantic sequence can be reordered.

### Rendering a patch on a controlled terminal

There is no sound general `Patch.to_updates : Patch.t -> Update.Batch.t`. A patch says what physical cells and presentation fields change, but terminal control sequences are interpreted relative to a terminal's current cursor, modes, margins, style, character set, and dimensions. Applying a patch to an unknown terminal could therefore draw a different result.

Provide an optional pure `Tessera.Repaint` layer for applications that *own* the target terminal:

    Patch.t
      │  (known target lineage/generation required)
      ▼
    Repaint.compile description policy
      │
      ├─► next Repaint.target
      ▼
    Update.Batch.t
      │
      ▼
    Encoder.encode description policy
      │
      ▼
    encoded control-character byte chunks ──► owned terminal output stream

    type target                         (* opaque, controlled output projection *)
    val compile : Description.t -> Policy.t -> target -> Patch.t
      -> (target * Update.Batch.t, Repaint.error) Err.t

`target` has opaque lineage/generation identity and the encoder-relevant
controlled state. `compile` accepts a patch only when both its lineage and
`before_generation` match that target. It first applies the absolute patch to
the target projection, then emits a canonical, ordered update batch (cursor
positioning, style changes, text/blank-cell writes, presentation changes).
The application then passes that batch to `Encoder.encode`; Encoder itself
remains a stateless update-to-bytes component.

The compiler explicitly rejects a patch it cannot faithfully express for the selected description, including unsupported attachments, an incomplete wide-glyph pair, or a presentation feature without a capability. On a new or desynchronised target, the application must establish a documented canonical baseline and issue a full repaint; it must not pretend a sparse patch is safe. This layer is for a controlled application renderer, never the transparent proxy, which must forward the source bytes rather than re-encode them.

Encoding is deliberately not a byte-level inverse of decoding: different escape
spellings, parameter defaults, and equivalent capabilities can produce the same
updates, so `decode (encode ...)` must not be compared with the source bytes.
It does have a valuable controlled round-trip contract. For a patch in the
declared repaintable subset (supported description, canonical baseline, no
unencodable observation/attachment, and no intervening terminal mutation),
start a reference decoder/renderer and `Repaint.target` from the same
pre-patch projection.  Then:

    Patch.t → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply

must produce the same normalised `Patch.t` and successor screen projection as
the original patch.  The test compares semantic patch fields after
`Patch.normalize`, not the emitted bytes or incidental parser provenance.  It
is the primary end-to-end verification for the controlled-output path.

### Decoder

Tessera.Decoder publishes a private serialisable continuation and a feed operation returning:

    continuation
    updates: Tessera.Update.Batch.t
    observations: Tessera.Effect.Observation_sequence.t

The continuation holds only finite parser state: pending UTF-8 bytes; ESC/CSI parameter/intermediate state; and bounded OSC, DCS, APC, and PM framing. It contains no grid, cursor, renderer state, or raw-stream history. Preserve the order between updates and observations internally, even if the public result groups them for convenience.

### Logical renderer

Tessera.Renderer owns state with:

    screen: private persistent paged physical grid
    cursor: position, pending-wrap flag, current style
    buffer_state: grid, cursor/saved cursor, margins, tabs, provenance
    state: primary, alternate, active buffer, modes, title, palette, history
    damage: changed rectangles, cursor-change flag, full-redraw flag
    snapshot: size, immutable cells, cursor, presentation modes, title, generation
    applied: successor state, damage, optional snapshot, observations, responses

apply accepts policy, state, and update batch and returns an applied value or a typed renderer error. Use a persistent page/chunk grid, not an array copied for each update. Snapshots export safe immutable values, never grid internals. A capture/query request is evaluated at its exact place in the batch, after earlier updates and before later ones.

### Terminfo, encoder, and checkpoints

Tessera.Terminfo accepts resource = Source of string or Compiled of bytes and returns parsed capabilities without filesystem access. Validate compiled offsets, counts, endianness, cancellation, and parameter-expression syntax. Represent the terminfo percent language as a capability-program AST/bytecode, evaluated by the encoder without arbitrary code execution. Store the bundled xterm-256color source as package data and parse it through the same public route.

Tessera.Encoder.encode receives description, policy, and update batch; it returns byte chunks or a typed encode error identifying the first unexpressible operation. It has no screen state or continuation.

Tessera.Checkpoint contains a versioned policy/description identity, decoder continuation, renderer state, and observer sequence positions. Restoration validates version and limits before returning runnable values.

## Error reporting: use the local err_trace clone

Use the cloned err_trace library at err_trace/ as the required error wrapper, instead of string errors or exceptions. Wire it as a local development/opam pin first; CI must build terminal packages against this checkout, then later also against a released version-constrained opam package. Require Dune 3.15+ and OCaml 4.13+, satisfying err_trace while retaining the repository's baseline.

Each component declares a local polymorphic-variant `type error = [ ... ]`, `pp_error`, a local `Error` domain module, and `module E = Err.Make(Error)`. There is deliberately no global `Tessera.Error` registry. A composition component (for example Session) defines its error type as an explicit union/wrapping of the domains it composes. Every public fallible core function returns `('a, error) Err.t`, rather than spelling the underlying `Stdlib.result`/`Err.Error.t` representation. Detection sites use E.fail with position __POS__; pure module boundaries use E.map_error; third-party/system result conversion uses E.import. Proxy boundaries use E.export for a payload-only client error and log the full Err.Error.pp value locally. Do not place Err.Error.t provenance in snapshots, wire messages, or terminal replies.

Set Err.Config.deterministic at normal proxy startup: it keeps bounded semantic boundary trails while making diagnostics portable across native OCaml, JSOO, and Melange. Test/development runs may select debug. Install an Err.Monitor only in adapters/CLI logging, with a short non-blocking callback. Recoverable malformed input is a bounded Effect.observation; Err failures are for operations that cannot continue under their published contract.

## External dependencies

| Scope | Dependency | Plan |
| --- | --- | --- |
| Portable core | OCaml standard library: Bytes, Buffer, Uchar, Format, Map, Set, Int64, Result | Required. Define the project's own non-owning byte slice as `bytes * off * len` for zero-copy calls; copy only fragments the parser must retain and audit/snapshot data. No Unix, threads, files, environment, clock, or random access in the core. |
| Portable core | err_trace (module Err), local clone at err_trace/ | Required for typed recoverable errors, bounded provenance, and printers. It has no runtime dependency of its own. |
| Portable core | uutf, uuseg, and uucp | Incremental UTF-8 codec, grapheme segmentation, and character properties/width inputs. Pin a mutually compatible release whose `unicode_version` is exactly 15.1, and verify native, JSOO, and Melange builds. Never use host locale, ICU, fonts, or JS `Intl` for terminal semantics. |
| Portable core | Terminfo parser and bundled xterm-256color definition | Implement in tree. Discovery/loading remains an adapter responsibility. |
| Proxy protocol | Existing local FlatBuffers OCaml runtime and flatc.ocaml | Proxy-only. Define a versioned tessera_observer.fbs for snapshots, traffic, effects, and requests. Keep the semantic core independent of the wire schema. |
| Linux proxy | Unix and small audited C stubs linked to POSIX openpty/forkpty, ioctl(TIOCSWINSZ), signal/process primitives, and libutil where needed | Required only for initial Linux proxy. Hide behind Tessera_proxy_platform.S. |
| Integration adapters | lwt, async, and their Unix/browser packages | Separate packages drive the pure session-step API; neither appears in the portable core's public types. `tessera-lwt` targets native plus JSOO with `js_of_ocaml-lwt`; `tessera-async` is native/OCaml-5-only. |
| Linux proxy | System terminfo database | Runtime resource. Adapter reads bytes and passes them to pure parser; failure uses the bundled parsed fallback. |
| Test only | ppx_expect, Alcotest, QCheck, benchmark, memtrace, and a fuzz harness | Prefer expect tests for protocol fixtures; use Alcotest/QCheck for generated properties. Reuse the repository's native `benchmark` and `memtrace` tooling for allocation profiles. Fuzz decoder and compiled-terminfo parser; test random chunking and checkpoint restore. |

The first release uses a select/poll loop in the Linux adapter. Other platforms provide their own stream adapters while the core remains free of scheduler, UI, filesystem, compression, and font-shaping dependencies.

## Byte streams and pluggable I/O

The core is scheduler-independent because its session transition is a total, synchronous state step:

    type input = { bytes : bytes; direction : direction; len : UInt.t; off : UInt.t }
    type output = { events : Event_sequence.t; next : session }
    val ingest : session -> input -> (output, Session.error) Err.t

`ingest` consumes its input before returning. It may retain only a copied bounded suffix for an incomplete UTF-8/control sequence. This gives direct callers a zero-copy path for any borrowed buffer, yet keeps continuations, checkpoints, and observer records independent of buffer lifetime. `event` includes byte-forwarding instructions, state/snapshot changes, typed effects, and bounded diagnostics in one order-preserving sequence.

An adapter owns scheduling. It reads a chunk, invokes `ingest`, serially writes the requested original bytes, publishes or drops observation events according to the bounded observer policy, then reads the next chunk. Each direction has one ordered write queue; adapters must never issue concurrent writes on the same terminal/application stream. A failed write, read, or task is mapped to its adapter error domain with `Err.import`. Checkpoints are taken only between completed `ingest` calls, never while an I/O promise/deferred is outstanding.

### Lwt, Core.Async, and JavaScript adapters

Provide separate packages sharing a small adapter test suite:

| Adapter | Read/write driver | Availability |
| --- | --- | --- |
| `tessera-unix` | Blocking `Unix.read`/partial-write/select loop | Initial Linux proxy only. |
| `tessera-lwt` | Lwt promise-based byte reads and writes, sequenced recursively around `ingest` | Native; JSOO via `js_of_ocaml-lwt` where the transport is browser-supported. |
| `tessera-async` | `Reader.read` and `Writer.write` chained with `Deferred.bind` around `ingest` | Native OCaml 5/Jane Street environment only; no browser promise. |
| `tessera-jsoo` | Bind WebSocket, Web Serial, or WHATWG `ReadableStream`/`WritableStream`; turn each `Uint8Array` chunk into the core slice and await writes in order | Browser/Node builds. A browser terminal normally connects to a server-side PTY; it cannot create a Unix PTY itself. |
| `tessera-melange` | Bind JavaScript `ReadableStream`, WebSocket, Node streams, or Promises; serialise callbacks/promises around `ingest` | Browser/Node builds. Do not use `Unix` or native stubs. |

For both JavaScript backends, transport bytes are `Uint8Array`, not JavaScript strings. The adapter copies each received chunk into transient OCaml `bytes`, calls `ingest`, and converts emitted bytes back to `Uint8Array`; terminal decoding still uses the pinned OCaml Unicode logic. Browser backpressure uses `ReadableStream` pull/reader readiness and awaited writable promises; Node adapters use an async iterator. A slow observer is independently lossy and must never stall the terminal byte path.

Adapter conformance tests use a scripted source/sink that simulates arbitrary chunking, short writes, backpressure, EOF, read/write failures, and observer disconnection. Run the same cases against the Unix, Lwt, Async, JSOO, and Melange drivers available in CI; assert identical ordered core events and transparent byte output. This grounds the claim of pluggability without requiring all runtimes in one package.

## Parsing strategy

### Terminal byte decoder

Implement an incremental ECMA-48/VT parser as a table-driven finite-state machine. Dispatch on byte ranges (C0, ESC, CSI parameter, CSI intermediate, final, and string-control bytes), accumulating only bounded parameters and payloads. UTF-8 decoding is a separate continuation feeding printable scalars into the active character-set mapping.

A direct byte-class dispatch is constant-space apart from policy-bounded buffers, naturally exposes source byte offsets, and makes malformed-input recovery explicit.

### Terminfo: source scanner, semantic pass, then compiled reader

Implement the source and compiled forms separately but lower both into the same `Tessera.Description` capability map.

1. Source format: write a small ASCII scanner with byte offset, line, and column spans. It recognises blank lines; beginning-of-line comments; a column-zero names/header field; indented comma-separated capability fields; and escaped comma, backslash, caret-control, and octal escapes. Parse each field into `Boolean`, `Number`, `String`, `Cancelled`, or `Use` AST nodes before unescaping/validating the value. This follows terminfo's simple comma-separated source grammar and produces precise `err_trace` diagnostics.
2. Semantic pass: validate aliases and known capability names/types; preserve unknown extension capabilities as typed extension data; compile only the required string capabilities' percent expressions into the safe capability-program AST. A `use=name` field remains an unresolved pure value until supplied descriptions are merged by a pure resolver. The core never opens a database; a self-contained source entry works directly, while a missing requested include is an explicit error.
3. Compiled form: use a bounds-checked little-endian reader for the legacy and ncurses extended layouts. Validate the magic, header counts, boolean block/alignment, signed numeric table, string-offset table, string-table NUL termination, and extended capability section before allocating proportional structures. Map standard capability indexes through a checked-in specification table; retain extensions separately. Reject arithmetic overflow, invalid offsets, unsupported format revisions, and policy-limit excess as typed errors.
4. Capability parameters: implement the terminfo percent-language as a direct stack-machine compiler, separate from source parsing. Support only the documented operations needed by the release-one capability set; reject unsupported operations rather than evaluating a format string dynamically.

Golden tests run `tic`/`infocmp` only as external fixture producers, never as part of the pure parser implementation. Test the bundled source, real system compiled entries, escape-heavy source examples, malformed/truncated corpus cases, extension data, and unresolved/cyclic `use` graphs.

## Tests, performance, and allocation budgets

Use expect tests as the primary readable protocol specification. Each test prints a stable, custom pretty-printer for updates, observations, damage, snapshots, terminal descriptions, and typed error payloads; never print `err_trace` stacks or memory addresses in expect output. Keep byte inputs written with visible escapes/hex and add a named fixture for each rule or compatibility decision.

| Test layer | Approach and required checks |
| --- | --- |
| Expect fixtures | `ppx_expect` tests for decoder sequences, terminfo source/compiled parsing, renderer state transitions, encoder bytes, resize/no-reflow, query ordering, and diagnostics. Identical fixture suites run on native, JSOO, and Melange, with backend-neutral output. |
| Property tests | QCheck generates arbitrary byte chunk boundaries, valid/invalid CSI parameters, cell edits, dimensions, and checkpoints. Assert chunking/restoration equivalence, bounded diagnostics, encoder determinism, renderer invariants (wide-cell pairing, in-bounds cursor/margins, no aliasing of old state), source/compiled terminfo equivalence, and the controlled `Patch → Repaint → Encoder → Decoder → Renderer` round trip for the repaintable subset. |
| Fuzzing | A native fuzz executable feeds random and corpus-mutated bytes to decoder and compiled-terminfo reader under small limits. It must never raise unexpectedly, loop, allocate beyond configured bounds, or lose framing synchronization. Keep minimized crashers as expect fixtures. |
| Allocation regression tests | Native-only tests warm the code path, force a major collection, use `Gc.allocated_bytes` around a fixed iteration count, and compare allocations per byte/update against versioned, deliberately generous budgets. Cover printable runs, one-cell edits, scrolls, SGR changes, resize, alternate-screen switching, snapshot creation, and long history eviction. Run release profile and repeat enough times to detect a real regression without making CI sensitive to one-off runtime noise. |
| Structural memory tests | Expose a test-only renderer statistics API: live pages, copied pages, retained cells/lines, history bytes, and audit-ring bytes. Assert a single-cell update copies only its page/path, history and audit rings never exceed policy, and a snapshot cannot pin unbounded obsolete grids. This is the portable memory oracle for JSOO and Melange, where GC heap measurements are not comparable. |
| Profiling and benchmarks | Add native release executables using the existing repository pattern of `benchmark` plus `memtrace`. Record baseline traces for realistic shell, editor, and scroll workloads; inspect allocation hot paths before changing the grid/layout representation. Keep benchmark numbers informational, while allocation and structural budgets are CI gates. |

Use `memtrace` for sampled/full allocation provenance during native investigation. JavaScript runs use the same functional fixtures and structural bounds; JavaScript heap measurements are not allocation gates because the collector is runtime-controlled.

## Proxy organisation

Tessera_proxy_linux is allowed mutable descriptors and process handles, but every protocol transition is a pure-core call with immutable values. Its session state contains decoder continuation, renderer state, description, policy, a next sequence number, and bounded directional audit rings.

Application-to-terminal bytes are written verbatim to the system terminal and decoded from an observational copy. Terminal-to-application bytes are likewise relayed verbatim; classify input, terminal reply, or unknown only where the protocol makes it safe. Resize notifications become ordered Resize updates. Transparent mode never manufactures a query reply.

The observer server begins as an authenticated/local Unix-domain connection using the versioned FlatBuffers schema. It publishes a current snapshot plus ordered traffic/effect records and explicit policy/authority metadata. Backpressure is bounded: a slow observer receives a reported gap rather than blocking terminal relay. Observer clients cannot inject terminal bytes in release one.

## Implementation milestones

| Milestone | Deliverable and exit criteria |
| --- | --- |
| 0. Package and build skeleton | Create terminal Dune packages, public boundaries, local err_trace wiring, the borrowed-slice/session-step API, pinned Unicode-library compatibility verification, expect-test harness, and FlatBuffers observer schema. Portable packages build on native, JSOO, and Melange; Linux code is excluded elsewhere. |
| 1. Shared model, policy, diagnostics | Implement Types, Style, Cell, Mode, Effect, Update, validated Policy, and local polymorphic-variant error domains using Err.Make. Add stable custom printers and expect tests for bounds, ordering, and deterministic trace configuration. |
| 2. Descriptions and terminfo | Implement the bounded handwritten source scanner, semantic include resolver, compiled binary reader, capability-program compiler, family selection, and bundled fallback. Expect and fuzz fixtures prove source/compiled equivalence and malformed data neither crashes nor reads files. |
| 3. Incremental decoder | Implement the table-driven C0/ESC/CSI state machine and UTF-8, then bounded string controls, SGR, character sets, modes, queries, and unsupported observations. Property/fuzz tests prove arbitrary chunking and checkpoint/restore match uninterrupted decoding. |
| 4. Immutable renderer | Implement paged primary/alternate grids, cursor/margins/tabs, editing/erase/scroll, styles/wide cells, provenance, title/palette, capture ordering, damage, snapshots, and bounded history. Test update fixtures without parsing bytes; resize is explicitly no-reflow. Add structural sharing invariants and native allocation budgets before optimising. |
| 5. Encoder and controlled repaint | Encode the release-one subset under selected capabilities and reject unexpressible updates with typed errors. Add `Repaint.compile` for owned terminals: it checks lineage/generation, lowers a patch to an ordered update batch, and sends that batch through Encoder. Test deterministic canonical bytes and the controlled normalised-patch round trip; document that decoding and encoding are not byte inverses. |
| 6. Composition and persistence | Add decode-to-apply-to-encode tests, versioned checkpoints, restore/limit checks, cross-backend conformance fixtures, and scripted I/O-adapter contract tests. The core must still have no I/O dependency. |
| 7. Linux transparent proxy | Add audited PTY/process and discovery adapters, byte-for-byte relay tests, resize propagation, fallback advertisement, bounded audit rings, and local observer server. Validate ordinary shell and full-screen applications against the declared subset. |
| 8. Release hardening | Add corpus fuzzing, release-profile allocation regression checks, memtrace workload baselines, memory-limit and slow-observer tests, C-stub/effect security review, compatibility matrix, documentation, and reproducible builds. Release only when the acceptance criteria in terminal-idea.md are met, not pixel/byte-for-byte emulator equivalence. |

Milestones 1 through 5 stay independently testable. Proxy integration must not become the sole evidence for parser, renderer, encoder, or terminfo correctness.
