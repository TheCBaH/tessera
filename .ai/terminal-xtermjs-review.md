# Tessera: xterm.js implementation review

This is a comparator review, not a proposed JavaScript dependency. It records
implementation-specific observations separately from the portable terminal
design.

Review basis: xterm.js commit
[`6a49e1a`](https://github.com/xtermjs/xterm.js/tree/6a49e1a) (cloned from
`https://github.com/xtermjs/xterm.js/` on 2026-08-22).

## Emulator family and advertised identity

xterm.js is a JavaScript terminal emulator, with both browser-rendered and
headless forms; it is not a Unix terminal device or a byte relay. Its core
describes itself as a VT100-derived implementation extended with xterm control
sequences; see
[`CoreTerminal.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/CoreTerminal.ts#L7-L24).
The parser is explicitly based on a VT500-compatible DEC/ANSI state table,
while the installed operations include VT100/VT220-style behavior, xterm
extensions, mouse modes, OSC features, and selected newer protocols.

The `termName` option defaults to `xterm`, but it does not choose a different
parser or screen model. It primarily changes selected device-attribute replies
and related compatibility behavior; see
[`OptionsService.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/services/OptionsService.ts#L48-L62)
and
[`InputHandler.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/InputHandler.ts#L1706-L1785).
It should therefore be understood as a configurable xterm-like hybrid, not as
an exact emulation of one physical DEC model or a claim that `TERM` alone
defines its accepted grammar.

## Control-stream decoding

`InputHandler.parse` accepts either JavaScript strings or `Uint8Array` bytes.
It incrementally decodes them to UTF-32, retains parse continuation across
chunks, and passes code points to `EscapeSequenceParser`; see
[`InputHandler.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/InputHandler.ts#L430-L497).
The parser uses a generated-style transition table with ground, escape, CSI,
DCS, OSC, APC, and ignore states. It recognises both 7-bit introducers such as
`ESC [` and C1 introducers such as `0x9b`; see
[`EscapeSequenceParser.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/parser/EscapeSequenceParser.ts#L94-L230).

Framing is separate from meaning. The input handler registers semantic
handlers for C0/C1 controls, ESC, CSI, OSC, DCS, and APC. For example, C0 line
feed, carriage return, backspace, tab, shift-in/out and selected C1 controls
have direct handlers, while CSI handlers cover cursor/editing/modes/SGR/query
operations; see
[`InputHandler.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/InputHandler.ts#L206-L283).
Unknown sequences fall back to logging rather than becoming screen text.

The public API also permits add-ons to install sync or async handlers. An async
handler pauses parsing and requires ordered continuation of the same chunk;
the implementation documents this as essential to avoid corrupting terminal
state. See
[`EscapeSequenceParser.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/parser/EscapeSequenceParser.ts#L574-L600).
That extensibility is useful for a browser product, but it is not suitable for
Tessera's deterministic, callback-free portable decoder.

## Resize is an explicit API event

The public API accepts a column and row pair, passes it into the core, and
publishes an `onResize` event. See
[`Terminal.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/headless/public/Terminal.ts#L66-L75)
and its
[`resize` implementation](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/headless/public/Terminal.ts#L129-L132).
The buffer service then performs the buffer resize and reports whether columns
and/or rows changed; see
[`BufferService.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/services/BufferService.ts#L49-L55).

The headless implementation returns early for an equal grid size; see
[`headless/Terminal.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/headless/Terminal.ts#L85-L98).
That is suitable for an
in-process renderer event, but it is not sufficient for a transparent proxy:
a host resize indication at equal cells can still require an application
notification. The proxy therefore preserves that indication in its ordered
out-of-band ingress, while an adapter may still avoid unnecessary graphical
work.

## Browser layout has more than one geometry

The browser terminal's resize handling updates the buffer and renderer
services; see
[`CoreBrowserTerminal.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/browser/CoreBrowserTerminal.ts#L1056-L1062).
Its dimensions service also has cell, canvas, and device-pixel values. This
supports keeping terminal grid dimensions separate from optional pixel
metadata, including an explicit unit, rather than treating browser CSS pixels
as PTY pixels.

For a browser attachment, grid size should be taken only after layout has
settled and all dimensions are valid. Transporting that result to a remote PTY
remains an explicit control path; a local browser resize event does not cross
the network by itself.

## Reflow is a policy, not an inevitable consequence of resize

xterm.js has substantial buffer reflow logic for width changes; see
[`BufferReflow.ts`](https://github.com/xtermjs/xterm.js/blob/6a49e1a/src/common/buffer/BufferReflow.ts#L16-L51).
That work changes wrapped-line structure and consequently has implications for
cursor placement, selection, scrollback, and snapshots. It reinforces the
design choice to make no-reflow versus reflow an explicit, declared session
policy. Tessera's first release remains no-reflow; any future reflow mode
needs its own compatibility and observer contract.

## Boundary for Tessera

The useful transferable lessons are explicit resize ingress, a completed-layout
boundary for browser adapters, and separate grid/pixel notions. The browser
renderer, add-on lifecycle, and JavaScript buffer model remain outside the
portable OCaml core.
