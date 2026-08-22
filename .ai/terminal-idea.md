# Pure Functional OCaml Terminal Protocol Library

## Project brief

Design a platform-independent, purely functional OCaml library for terminal
protocols. The core library has three composable parts:

1. A **decoder**, which observes bytes sent by a terminal application and
   translates them into ordered, semantic terminal updates and typed effects.
2. A **logical renderer**, which receives those updates and an immutable
   terminal state, then applies them to produce the next state, screen damage,
   snapshots, and derived observations.
3. An **encoder**, which accepts those semantic terminal updates and turns them
   into byte sequences for a selected terminal description.

All three are pure functions. The decoder does not mutate or own a rendered
terminal state. The logical renderer is the state-transition component; it is
not a pixel, font, or windowing renderer. This separation is intentional:
parsing and protocol validation can be tested without constructing a screen,
while screen semantics can be tested independently of byte syntax.

The initial consumer is a transparent terminal proxy. It runs the user
application in a PTY-backed terminal environment and sits between that
environment and the user's existing system terminal. The proxy must pass the
application's terminal output through unchanged while decoding an observational
copy of it. In the other direction it relays user input and terminal replies to
the application. This makes the proxy non-invasive: decoding must not require
the application to use a special terminal protocol or renderer.

Alongside the relayed stream, the proxy exposes an out-of-band observation
channel. It provides the library's current projection of the display: the
visible grid, cursor, modes that affect presentation, title, and approved
metadata/effects. It also reports the ordered byte traffic in each direction,
with protocol classifications where they are knowable. This is the defined
meaning of "peek": a consumer can inspect what the supported terminal model
says is on screen and audit the interaction without injecting anything into the
user's terminal session. Bytes arriving from the system terminal cannot always
be attributed as user input versus a terminal-generated reply, so the proxy
reports their direction faithfully and makes attribution best-effort.

The core library has no dependency on PTYs, operating-system I/O, rendering,
or filesystem access. Those concerns belong to adapters and to the proxy
application.

## First-release terminal contract

The first proxy release supports a PTY environment whose advertised value is
`TERM=xterm-256color`. Its behavioral contract is the documented,
VT/xterm-compatible subset normally expected by well-behaved applications using
that terminal type. It is not a promise to emulate every xterm resource,
private extension, or behavior selected by a user's local configuration.

The initial supported behavior includes UTF-8 text; C0 controls; ESC, CSI, DCS,
OSC, APC, and PM string framing; cursor movement; editing and erasing; margins,
tabs, scrolling, origin and wrap modes; SGR including indexed 256 colors and
RGB color; character sets needed for common xterm line drawing; primary and
alternate screens; cursor visibility and save/restore; bracketed paste, focus,
and SGR mouse modes; window-size changes; titles; and terminal status/device
queries used by ordinary xterm-compatible applications.

The proxy's logical renderer tracks the display state implied by this contract.
The proxy forwards the original output stream, including extensions it does not
understand, so that the user's terminal remains the authority for rendering the
actual stream. Consequently, its observation is authoritative for the supported
subset and a best-effort model outside it. It cannot reliably report
terminal-local state outside the application's control, such as the user's
scrollback viewport, font fallback, user-selected text, or emulator-specific
configuration.

## Terminal descriptions and terminfo

Terminfo is an external resource from the first release. The library accepts a
terminfo resource supplied by an adapter, parses it into a portable terminal
description, and reports an invalid or incomplete resource without relying on
the host operating system. The supported resource forms include the ordinary
compiled terminfo entries used by system databases and a portable terminfo
source definition. Resource discovery itself is outside the pure core.

For the proxy, terminal selection is deliberate:

1. It discovers the terminal type the existing system-terminal session says it
   presents and asks its platform adapter to locate the corresponding terminfo
   resource.
2. It parses that resource and selects the declared behavioral family that the
   proxy can faithfully model.
3. If discovery, loading, parsing, or family selection fails, it uses the
   bundled `xterm-256color` terminfo definition, parsed through the same public
   path as an external resource, and advertises that fallback to the PTY-side
   application.

The first supported behavioral family is `xterm-256color`; compatible aliases
may use it when their parsed capabilities are consistent with it. Parsing a
different terminfo entry is useful for inspection and diagnostics, but does not
by itself authorize the proxy to advertise or emulate an unsupported terminal
family. This prevents an application from being told that it has capabilities
the decoder cannot observe reliably.

Terminfo supplies concrete application-to-terminal capability sequences, not a
complete account of terminal behavior. Private modes, parsing rules, queries,
and extensions remain defined by the selected behavioral family. Future
descriptions add an explicit behavior-family compatibility statement in
addition to their terminfo data.

## Decoder: terminal-emulator side

The decoder consumes application output incrementally and produces ordered
batches in the shared terminal-update language, together with typed
observations. It owns only the small continuation needed to parse a fragmented
byte stream, such as an incomplete UTF-8 character or control string. It does
not own, inspect, or mutate the terminal screen state while decoding.

The update batch describes the semantic consequences of the bytes: printing
text, executing controls, moving or saving the cursor, changing attributes,
editing cells or lines, setting modes and margins, switching screens, resizing,
changing title or palette-related state, and making protocol requests. The
batch preserves byte-stream order. Where a sequence depends on terminal state—
for example character-set selection, origin mode, margins, or wrapping—the
decoder emits the operation rather than precomputing its resulting cells or
coordinates. The logical renderer resolves that operation against the supplied
state, applies specified no-op or clamping behavior, and reports a batch that
is invalid under the selected policy. State-dependent validation is therefore
not coupled to parsing.

The decoder does not need to retain raw control sequences to make a screen
capture. The proxy's directional interaction record is the separate, bounded
source for audit or replay of original bytes. A capture is instead derived from
the state produced when a valid update batch is applied; it is a terminal-cell
capture, not a pixel capture. Font selection, shaping, and rasterization remain
renderer-owned.

For the proxy, the decoder is observational: it never changes the bytes chosen
for transparent forwarding. In transparent mode, terminal queries pass to the
user's terminal and the replies observed in the return stream pass back to the
application. The library records queries and replies as typed observations; it
does not manufacture, suppress, or perform them. In a non-proxy embedding, the
host may instead choose how to satisfy a request.

Malformed, unknown, and unsupported input has a single compatibility policy:
the decoder preserves parsing synchronization, produces no state-changing
update where no supported meaning exists, and emits a bounded
diagnostic/observation. Unterminated or oversized string controls are discarded
according to configured resource limits until their boundary can be recognized.
The proxy still forwards those original bytes unchanged.

## Encoder: terminal-application side

The encoder consumes batches in the same terminal-update language and emits
sequences for a selected terminal description. It is pure: it does not retain a
mutable output-protocol state or apply updates to a screen. An application that
uses the encoder can apply the same batch to its own state model when it needs a
predicted result.

The initial encoder covers text, cursor and screen operations, styles and
colors, scrolling, screen switching, mode selection, queries, and the
input-reporting protocols in the first-release terminal contract. Multiple
representations of the same update may be selected only when the selected
description declares them compatible. An update that the target description
cannot express is reported as such; it is never silently approximated.

Sharing the language does not make encoder and decoder mathematical inverses.
The decoder normalizes multiple byte forms into one semantic update, and the
encoder selects one compatible byte form for an update. The logical-renderer
rules—not either byte conversion—are the authoritative definition of what an
update means.

## Logical renderer, shared update language, and state model

The decoder, logical renderer, and encoder share an immutable terminal-update
language. It covers text, controls, cells, styles, colors, cursor positions,
modes, screen operations, terminal effects, capability families, descriptions,
feature negotiation, and compatibility policies. Its instructions express
operations rather than a replacement screen image, so they are meaningful to
both encoding and state application.

The logical renderer owns application-controlled terminal state: primary and
alternate screens, cursor and saved state, modes, tabs, margins, character
sets, palette-related state within the supported scope, parser-neutral protocol
state, and an optional bounded logical history. It applies an update batch
purely, yielding a successor state and precise damage/observations. The host UI
owns scrollback browsing, selection, viewport position, fonts, pixel geometry,
and final rendering of images or links. The snapshot exposed by the proxy is
the current logical terminal view, not a claim about a system terminal's
UI-owned viewport.

Physical cell placement is canonical for logical-renderer semantics: cursor
addressing, erasure, margins, insertion, and scrolling act on the physical
grid. To avoid a later data-model break, state also preserves the logical-line
provenance of that grid: hard line boundaries, soft wraps, cell-to-line
association, and the information required to lay out grapheme clusters and wide
cells at a new width. This applies to retained history as well as the primary
screen. Content that is not text is represented as an attachment or placeholder
with stable layout semantics, so a later graphics feature does not require
changing the meaning of a cell.

Resizing does not reflow existing content in the first release. The model
applies the new dimensions while retaining the provenance needed for a future
reflow policy. That future policy must specify which buffers are eligible, how
cursor and selection anchors map, how margins and edits affect line provenance,
and how attachments participate. The alternate screen remains a physical-grid
screen unless a later specification explicitly says otherwise.

## Restartability and checkpoints

Every component is restartable because all continuation is explicit immutable
data. The decoder is resumed with its parser continuation and the next input
bytes; the logical renderer is resumed with its terminal-state snapshot and the
next update batch; and the encoder is resumed with its terminal description,
policy, and next batch. None relies on hidden mutable process state.

Restarting a decoder at an arbitrary byte boundary without its continuation is
not valid: an incomplete UTF-8 sequence or control string would be ambiguous.
An empty continuation is valid only at a known stream boundary. A durable core
checkpoint is therefore created only after a completed ingress transition and
contains the versioned policy, decoder continuation, and logical-renderer
state. A proxy wraps it with its selected terminal-description identity and
observer position metadata. Neither form contains signals, descriptors, pixel
geometry, borrowed buffers, or adapter lifecycle state. Restoring the core
checkpoint is deterministic and performs no I/O; maintaining process, PTY, and
system-terminal connectivity across a restart is an adapter concern.

## Text and display-width policy

Text is interpreted as UTF-8, with a width policy based on the recorded
upstream Unicode submodule revisions.
Combining characters attach to the preceding printable cell when possible;
East Asian ambiguous-width characters are one column; wide and emoji
characters follow those tables. Invalid UTF-8 is rendered as a replacement
character and reported as a diagnostic.

This is deliberately deterministic, not an attempt to mirror every host
terminal's locale or font-dependent width decision. A proxy observation may
therefore differ in rare cases from a user's terminal configured with another
width policy; the out-of-band channel exposes the library's policy and active
dimensions so a consumer can judge that limitation.

## Effects, queries, and safety

The decoder expresses all external behavior as typed requests or observations.
This includes title changes, hyperlinks, clipboard requests, notifications,
device/status queries, and protocol diagnostics. A transparent proxy observes
and relays these without intervention. Other embeddings are responsible for
approval, terminal interaction, and any response sent to the application.

If a supported or future protocol operation requires a screen-derived capture
or response, the decoder emits a request in the shared update stream; it never
reads renderer state. The logical renderer evaluates that request at its exact
position in the batch, after prior updates and before subsequent ones, and
emits the resulting logical snapshot or response request. The host then decides
whether and how to return a response. Thus capture has an ordered data flow
from decoder to logical renderer to host, not a mutual decoder/renderer
dependency. Transparent-proxy mode continues to relay the real system
terminal's replies and does not fabricate capture replies unless a later proxy
mode explicitly opts into emulation.

Input and output streams are untrusted. Configurable, finite limits apply to
pending control strings, diagnostic payloads, logical history, image data,
decompression, and retained snapshots. Effects capable of exposing data or
changing user state are opt-in at the embedding boundary; the core library does
not access a clipboard, open a link, display a notification, or load content.

## Extensions and scope

The following are intentionally outside the first proxy contract: Sixel, Kitty
graphics, iTerm2 inline images, OSC 52 clipboard transfer, complete shell
integration, synchronized output, Kitty keyboard protocol, and exhaustive
vendor-specific behavior. The decoder recognizes their framing sufficiently to
remain synchronized and reports them as unsupported observations; the proxy
forwards them unchanged.

True color and OSC 8 hyperlinks are supported in the display model. Hyperlink
targets are exposed as data only, never activated by the library. New extensions
must declare whether they add decoder behavior, encoder capability, or both,
and whether they can make the proxy's screen projection non-authoritative.

## Portability

The decoder, encoder, terminfo parser, terminal descriptions, and shared
protocol model must build under native OCaml, JSOO, and Melange. Platform
adapters provide byte streams, PTY integration, terminal-size notification,
terminfo resource discovery, browser events, and rendering.

The first proxy adapter targets Linux. Its public proxy semantics must not
depend on Linux-only terminal behavior: macOS, the BSDs, and other Unix-like
systems are expected to supply equivalent PTY and terminal-stream adapters.
Platform differences in process control, signal handling, resize notification,
and terminal-device behavior are adapter concerns and must not change the core
terminal contract. Windows is not a first-release proxy target.

## Independent component testing

Each pure component must have tests that do not require the others:

- Decoder tests map byte fixtures to update batches, observations, and parser
  continuations. They must show that arbitrary input chunking and checkpoint/
  restore produce the same result as uninterrupted input.
- Logical-renderer tests apply update fixtures to state fixtures and assert the
  successor state, damage, snapshots, capture ordering, resource-limit
  behavior, resize behavior, and diagnostics without parsing bytes.
- Encoder tests map update fixtures plus a terminal description to emitted
  bytes or an explicit unsupported result, without constructing a screen.
- Terminfo parser tests map external and bundled resources to the same portable
  descriptions, independently of filesystem discovery.

Composition tests then cover decode → logical-render → encode behavior and
proxy relaying. They complement, rather than replace, the component tests; the
encoder/decoder non-inverse rule remains explicit.

## First-release acceptance criteria

The release is complete when a Linux proxy can discover and parse the system
terminal's terminfo resource, select the supported `xterm-256color` family or
fall back to its bundled parsed definition, run ordinary applications
transparently, provide an incrementally updated out-of-band screen projection,
and relay required user input and normal terminal replies without
application-specific integration. The supported update language must decode,
apply to immutable state, and encode deterministically under the declared
terminal description and policy.

Compatibility is measured against documented xterm-compatible behavior in the
declared subset, including interactive full-screen programs and shell use; it
is not byte-for-byte or pixel-for-pixel equivalence with xterm. The core must
remain deterministic for a given byte stream, terminal size, and declared
policy, and must keep memory consumption bounded by its configured limits.

## Non-goals

The initial project is not:

- a native terminal window or browser terminal widget;
- a shell, PTY implementation, or operating-system terminal driver;
- a universal parser for every undocumented terminal behavior;
- a renderer for fonts, glyph shaping, images, or host scrollback UI;
- a claim to observe terminal-local state that the byte stream does not reveal;
- a guarantee of byte-for-byte, pixel-for-pixel, or configuration-for-
  configuration compatibility with a specific terminal emulator.
