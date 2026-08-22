# Tessera: comparison with existing terminal software

## Purpose and scope

This is a landscape review for Tessera, not a dependency shortlist.  It covers
the relevant *applications* as well as libraries: terminal emulators,
multiplexers, remote-terminal systems, recorders, browser gateways, parsers,
and the OCaml ecosystem.  The comparison is deliberately broader than an opam
search: the architectural boundary of a terminal program matters at least as
much as its implementation language.

Tessera's intended boundary is unusual but useful:

    application / PTY  <->  transparent byte relay  <->  physical terminal
                                  |
                         pure decoder -> updates -> immutable state -> patches
                                  |
                           bounded observer/checkpoint API

The proxy copies each direction byte-for-byte.  The pure core interprets an
observational copy, but it neither owns the process/PTY nor draws a GUI.  Its
renderer means logical screen-state renderer, not a pixel, font, GPU, or
window-system renderer.  Consequently, no existing project is a drop-in
replacement for Tessera; several are excellent sources of tests, protocol
behaviour, and API lessons.

## Architectural map

| Kind | Representative projects | What they own | Relation to Tessera |
| --- | --- | --- | --- |
| Terminal emulator application | Ghostty, WezTerm, Windows Terminal, xterm.js, hterm | Screen model plus platform or browser rendering; often PTY/session integration | Reference implementations and potential front ends, not core dependencies. |
| Terminal-emulator library | libghostty, libvterm, termwiz, pyte, vt10x | VT parsing and a mutable or internal screen model | Closest semantic comparators.  Their API boundaries validate Tessera's separation, but their language/runtime and mutability do not meet Tessera's core goal. |
| Parser-only component | Alacritty `vte`, Windows Terminal parser, Charmbracelet `x/ansi`, OCaml `ansi` | Incremental escape grammar and dispatch events | Strong evidence for a small state-machine decoder that delegates semantics; direct design inspiration. |
| Multiplexer application | GNU screen, tmux, Zellij, WezTerm mux | PTYs, child processes, multiple virtual terminals, pane layout, attachment, history | A different product layer.  It terminates and re-emits terminal protocols; it is not a transparent observer. |
| Remote-terminal application/protocol | SSH clients, Mosh, WezTerm remote domains | Authentication, transport, latency/roaming policy, usually an emulator | Out of Tessera's first scope.  A later adapter may observe such a stream, but must not embed its own remote protocol. |
| Recorder, replay, inspection | asciinema, Termscope | Either a PTY/emulator that runs the command, or raw traffic/event recording | Directly adjacent use cases.  Tessera can provide an observation source, but should not initially become a recorder format or a command runner. |
| Browser terminal service | ttyd, wetty-style systems, xterm.js server integrations | PTY, server, WebSocket/auth, browser emulator | Potential deployment around Tessera, not a portable core concern. |
| Capability database/tooling | ncurses `tic`/`infocmp`, terminfo | Terminal capability descriptions and compilation | Authoritative fixture producers and runtime data sources; Tessera keeps parsing/evaluation pure and in-tree. |
| OCaml output/TUI library | Notty/Nottui, lambda-term, Miaou, terml | Application widgets/images, keyboard/mouse input, terminal output | Complementary consumers of a terminal, rather than interpreters of arbitrary terminal output. |

## Application-level comparisons

### Multiplexers: GNU screen, tmux, Zellij, and WezTerm

[GNU screen](https://www.gnu.org/software/screen/manual/html_node/Overview.html)
is a full-screen window manager which multiplexes one physical terminal over
several processes.  It gives each window a virtual VT100-like terminal,
scrollback, copy/paste, and detach/reattach.  [tmux control
mode](https://github.com/tmux/tmux/wiki/Control-Mode) exposes a text protocol
instead of drawing a normal client.  Modern applications such as
[WezTerm](https://wezterm.org/) bundle a terminal emulator and multiplexer,
including local/remote domains, panes, tabs, persistence, and UI integration.

They solve the user's session-management problem, not the transparent
observation problem.  A multiplexer is necessarily authoritative: it creates
PTYs, decides the virtual terminal's dimensions, parses application output,
and emits a new stream to each attached client.  It can therefore change
timing, replies, advertised capabilities, and escape sequences.  That makes
it inappropriate for Tessera's proxy path, whose success criterion is
byte-for-byte relay.

What Tessera should borrow:

- Treat the logical terminal as a separately testable component.  Screen's
  virtual terminals and tmux's control-mode boundary demonstrate the value of
  a headless semantic model.
- Make attachment/observation a separate protocol with explicit gaps and
  snapshots.  Do not let observer backpressure block the data path.
- Keep panes, windows, layouts, process lifetime, detach/reattach, key-prefix
  handling, and multi-client authority out of the initial project.  They would
  turn Tessera into a multiplexer and invalidate transparent-proxy assumptions.

Zellij is in the same application class and is useful as a UX comparison, but
adds no library boundary Tessera should copy.  WezTerm is a useful long-term
reference because its mux can exist without a GUI; it is still an owning,
stateful session service rather than an observer.

### Remote terminals: SSH and Mosh

[Mosh](https://mosh.org/) is a remote-terminal application built around a
state-synchronisation protocol: it supports roaming, intermittent links,
local echo, and adaptive frame rate.  This is deliberately not transparent
byte relay.  Its state replication is a useful contrast to Tessera patches:
both benefit from a compact state projection, but Mosh owns the connection and
its recovery semantics.

Tessera should not adopt SSH authentication, UDP transport, local echo, or
network reconnection in its core.  A future Mosh/SSH-facing adapter can feed
the already-observed bytes into the synchronous session API.  If Tessera later
offers remote observers, use its generation-tagged absolute patches rather
than mistaking them for a replacement remote-shell protocol.

### Recorders, replay, and inspection: asciinema and Termscope

[asciinema](https://docs.asciinema.org/how-it-works/) captures output at the
PTY master, which means it receives the original byte stream including control
and escape sequences.  Its [asciicast v3](https://docs.asciinema.org/manual/asciicast/v3/)
format is newline-delimited JSON events with output, input, resize, marker,
and exit events.  This is a good external interchange *format* for a later
exporter, particularly because resize and timing are explicit.  It should not
be a dependency or Tessera's internal event model: the core must remain JSON-
free and preserve typed updates/patches rather than textual JSON values.

[Termscope](https://github.com/mwunsch/termscope) is especially close in
purpose: it is a headless terminal-emulator CLI powered by `libghostty-vt`,
launching commands and exposing/interacting with their terminal state.  It is
therefore a useful acceptance-test comparator for snapshots, alternate screen,
and inspection ergonomics.  The boundary differs: Termscope owns the child
session and emulator; Tessera's first proxy observes a session that already
exists and forwards its bytes unchanged.  Tessera may later support a
Termscope-like application built on its core, but that is a new executable,
not a reason to put PTY ownership in `tessera`.

## Emulator and parser implementations

### Full or embeddable emulator cores

| Project | Relevant shape | Lesson for Tessera | Why not depend on it |
| --- | --- | --- | --- |
| [libghostty](https://github.com/ghostty-org/ghostty) | Embeddable C/Zig library for terminal emulation/style parsing; Ghostty documents a concrete VT support matrix. | A headless reusable core is valuable; use Ghostty's documented sequences as a behavioural reference. | Native FFI, its own mutable/runtime assumptions, and an external compatibility policy conflict with a portable pure OCaml core. |
| [libvterm](https://github.com/neovim/libvterm) | Historic C terminal-emulation library used by Neovim; its upstream fork is archived. | Stable callback-style embedding and a distinct screen model are useful historical references. | Archived upstream plus C FFI and imperative state; not appropriate as a new core dependency. |
| [termwiz](https://docs.rs/crate/termwiz/latest) | Rust facilities for display apps and building an emulator. | Keep parsing/state distinct from the outer display app. | Rust dependency/FFI and its own terminal/UI scope. |
| [Alacritty](https://github.com/alacritty/alacritty), [Kitty](https://sw.kovidgoyal.net/kitty/), and [Windows Terminal](https://github.com/microsoft/terminal) | Native terminal applications with their own rendering, platform integration, and extension/compatibility priorities. | Test common application behaviour, but make compatibility claims per named sequence family rather than attempting a generic “modern terminal” target. | They are end-user applications, not portable semantic libraries; their GPU/UI/platform choices are outside the core boundary. |
| [pyte](https://pyte.readthedocs.io/) | Python VTXXX emulator with an in-memory screen. | A small headless model can power screen scraping and replay; its tests are useful comparative cases. | Python runtime and mutable object model. |
| [vt10x](https://pkg.go.dev/github.com/gravitational/vt10x) and [go-te](https://github.com/rcarmo/go-te) | Go in-memory terminal backends; `go-te` explicitly carries diff/history screens and conformance-derived tests. | Dirty/diff screen APIs are worth comparing with Tessera's absolute patch API. | Go runtime, imperative/concurrent APIs, and no OCaml/JS portability. |
| [xterm.js headless](https://github.com/xtermjs/xterm.js/) | JavaScript terminal state implementation, alongside a browser terminal front end. | Excellent browser compatibility reference and potential independent oracle for fixtures. | It is a JavaScript runtime dependency with broader rendering/add-on concerns; Tessera must retain one vendored Unicode semantic implementation across native and JS builds. |

These projects provide two competing screen-change styles: dirty flags/diff
screens and callback/event streams.  Tessera should keep its planned
two-language distinction instead: ordered, state-dependent `Update` batches
at the protocol boundary and absolute, state-independent `Patch` values after
rendering.  A `Patch` is intentionally closer to a diff screen, but its
generation checks and composability make it suitable for observers without
exposing mutable dirty flags.

### Parser-only projects

[Alacritty's `vte`](https://github.com/alacritty/vte) is the clearest
precedent for the decoder boundary.  It is an ANSI parser state machine which
calls a `Perform` delegate for semantic actions; it does not decide how a
cursor or screen behaves.  The [Windows Terminal parser](https://github.com/microsoft/terminal/blob/main/src/terminal/parser/stateMachine.hpp)
has the same broad shape: a state machine retains parsing state across calls
and calls an engine interface, while its renderer is a separate subsystem.
Go's experimental
[Charmbracelet `x`](https://github.com/charmbracelet/x) similarly offers ANSI
parser/definition and cell-buffer packages.

Tessera should follow the *separation*, not the APIs: a table-driven,
incremental byte FSM emits typed `Update`/`Observation` items and keeps only
bounded framing/UTF-8 continuations.  The renderer alone applies cursor,
margins, wrap, and scroll semantics.  Regular expressions remain unsuitable
for this decoder: CSI/DCS/OSC are incremental languages with nesting-like
framing rules, cancellation/recovery, unbounded hostile inputs, and chunk
boundaries.  Regex can help only in offline fixture tooling, never on the
protocol data path.

### Browser-facing emulators and gateways

[xterm.js](https://github.com/xtermjs/xterm.js/) and
[hterm](https://github.com/chromium/hterm) are browser presentation/input
components.  They require an external transport and shell/PTY service.
[ttyd](https://github.com/tsl0922/ttyd) is an application which joins a command
or PTY to a browser terminal over a web service.  These confirm the deployment
split for a future web offering:

    native PTY/relay adapter  <->  authenticated transport  <->  xterm.js/hterm UI

The browser UI can display the real byte stream independently of Tessera while
an observer receives Tessera snapshots/patches.  Do not attempt to use OCaml
JS strings as the transport representation: JSOO/Melange adapters should use
`Uint8Array` and hand transient byte slices to the same pure decoder.

## OCaml ecosystem

| Project | What it provides | Fit |
| --- | --- | --- |
| [Notty](https://opam.ocaml.org/packages/notty/) / Nottui | Declarative composable terminal images; Notty has optional Lwt support. | A possible consumer for a future Tessera-inspection UI, not a VT output decoder or screen-model dependency. |
| [lambda-term](https://opam.ocaml.org/packages/lambda-term/) | High-level functional terminal manipulation: keyboard/mouse, colours, and widgets, with Lwt-oriented use. | Same complementary role as Notty; do not import it into the scheduler-free core. |
| [Miaou](https://opam.ocaml.org/packages/miaou-driver-term/) | Applicative UI framework with terminal, matrix/SDL, and web/xterm.js drivers. | Good evidence that UI drivers belong above a pure model; potentially a later observer UI. |
| [ansi](https://opam.ocaml.org/packages/ansi/ansi.0.7.0/) and `ansi-parse` | Basic ANSI parsing, chiefly suited to coloured/log output. | Too narrow for the terminal protocol and mutable-screen semantics required here; useful only as a small test/reference aid. |
| [terml](https://opam.ocaml.org/packages/terml/) / ANSITerminal | Terminal output and small TUI facilities. | Output-focused, so not a replacement for decoding unknown application output. |
| `uutf`, `uuseg`, `uucp` | Incremental UTF-8, Unicode segmentation, and properties. | Required portable building blocks, vendored as upstream submodules with Dune overlays. Update them deliberately without version constraints, and test all three OCaml backends. |
| `err_trace` (local clone) | Typed errors with contextual reporting. | Required core error wrapper as specified in `terminal-plan.md`; diagnostics crossing observer/protocol boundaries remain payload-only. |

There is no mature OCaml package that simultaneously offers a full,
incremental VT parser, immutable emulator state, portable native/JS semantics,
terminfo parsing, and transparent-proxy integration.  Composing Notty or
lambda-term with a small ANSI parser would still leave the hard pieces
(bounded decoder, alternate buffers, wide cells, scroll/margin semantics,
patch algebra, and parser recovery) unspecified.  Tessera should therefore
own those pieces, while using the Unicode and error libraries above.

## Terminal descriptions and terminfo

The [terminfo specification](https://pubs.opengroup.org/onlinepubs/7908799/xcurses/terminfo.html)
is the source-level reference.  `tic` and `infocmp` from ncurses are useful
fixture producers and diagnostic tools; the ncurses documentation also covers
the compiled database formats.  They must stay outside the semantic core:
executing a system program or reading a host database makes results dependent
on installation and is unavailable in browser builds.

Tessera should retain the proposed three layers:

1. An in-tree, bounded source scanner and compiled-entry reader lower into one
   pure `Description` value.
2. A separately compiled, safe capability-program evaluator emits byte
   templates; it never dynamically executes terminfo text.
3. The Linux adapter discovers system entries and passes their bytes to the
   pure parser.  The package contains a tested xterm-256color fallback.

This keeps *terminfo* on the encoding/description side.  It does not define
what arbitrary application output means; the decoder's advertised xterm
compatibility family does.

## Tests, compatibility, and performance references

No single terminal test suite establishes compatibility.  Use a layered
evidence strategy:

| Source | Use in Tessera | Limitation |
| --- | --- | --- |
| [VTTEST](https://www.columbia.edu/kermit/vttest.html) | Manually curated VT100/VT102 fixtures and human smoke testing. | Historic and interactive; it does not cover the modern extension set. |
| [Contour's conformance harness](https://github.com/contour-terminal/contour/blob/master/docs/internals/vt-conformance.md) | Model a headless harness which records known gaps; it drives both vttest and esctest. | Do not claim a score merely because an interactive menu ran. |
| xterm.js, Ghostty, pyte, and go-te behaviour | Differential/oracle investigation for carefully selected, documented sequences. | Divergence is evidence to examine, not a license to inherit undocumented behaviour. |
| ncurses `tic`/`infocmp` | Generate source/compiled terminfo fixture pairs. | Test tool only; never a runtime parser dependency. |
| [vtebench](https://github.com/alacritty/vtebench) | Shape realistic PTY-read benchmark payloads and compare throughput trends. | It measures PTY-read speed, not full frame latency or a general emulator ranking. |

Tessera's primary evidence remains repository-owned expect tests.  Each case
should show input bytes, chunk boundaries, ordered updates/observations,
snapshot, and canonical patch.  Add properties for arbitrary chunking,
checkpoint restoration, update application, and `Patch.compose` generation
laws.  Allocation gates should use `Gc.allocated_bytes` on native builds and
test-only persistent-grid statistics everywhere; use `memtrace` only for
investigation.  JavaScript heap size is not a stable cross-runtime gate.

## Decisions resulting from the comparison

1. Keep the core pure, immutable, and scheduler-free.  Existing UI and mux
   applications demonstrate useful outer layers but do not supply this
   boundary.
2. Keep `tessera-proxy` narrow: transparent PTY relay plus observation.  Do
   not turn it into screen/tmux/Termscope, a command runner, a recorder, or a
   web server in the first milestones.
3. Implement the incremental FSM and renderer separately, following the
   parser/delegate pattern established by `vte` and Windows Terminal.  Do not
   use regular expressions for protocol decoding.
4. Retain in-tree terminfo parsing and a fixed fallback description; use
   ncurses only to create fixtures or discover system data in adapters.
5. Depend only on portable OCaml foundations (`err_trace`, `uutf`, `uuseg`,
   `uucp`) in the core.  Keep Notty, lambda-term, Miaou, Lwt, Async, xterm.js,
   PTY code, and FlatBuffers protocol code in optional outer packages.
6. Treat Termscope, asciinema, screen/tmux, and xterm.js as acceptance and
   interoperability comparators.  Their applications may later be built
   *using* Tessera but should not determine the core's public types.
