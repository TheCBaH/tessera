# Tessera: tmux implementation review

This is a comparator review, not a proposal to depend on tmux or to adopt its
architecture.  tmux is a terminal multiplexer: it terminates PTY protocols,
maintains mutable virtual screens, chooses pane sizes for one or more clients,
and re-emits terminal output.  Tessera's proxy instead forwards application
bytes unchanged and maintains only an observational projection.

Review basis: tmux commit
[`c1f947a`](https://github.com/tmux/tmux/tree/c1f947a) (cloned from
`https://github.com/tmux/tmux.git` on 2026-08-22).  Linux/POSIX documentation,
not tmux, remains the authority for OS behavior.

## Resize and signals

tmux's client turns `SIGWINCH` into an internal `MSG_RESIZE` notification; it
does not treat the signal as containing dimensions.  The server then reads the
client TTY with `TIOCGWINSZ`, recalculates layout, redraws, and emits its own
resized event.  See [`client.c`](https://github.com/tmux/tmux/blob/c1f947a/client.c#L548-L549)
and [`server-client.c`](https://github.com/tmux/tmux/blob/c1f947a/server-client.c#L2668-L2687).

This supports the Tessera rule that a signal is a wake-up/lifecycle mechanism,
while a freshly queried, validated size is the semantic input.  Tessera should
use an event-loop-safe signal source (`signalfd` on the initial Linux adapter,
or a self-pipe on portable Unix adapters), not execute model work in a signal
handler.

tmux propagates a pane's resolved dimensions with `TIOCSWINSZ`, including
`ws_xpixel` and `ws_ypixel`, rather than only its in-memory screen dimensions.
See [`window.c`](https://github.com/tmux/tmux/blob/c1f947a/window.c#L581-L606).
The proxy must likewise pass the complete host `struct winsize` to the child
PTY.  Tessera's logical renderer currently needs only positive character rows
and columns; pixel fields are proxy/observer metadata, not renderer geometry.

tmux also retains a short resize queue.  When several pane resizes end at the
starting size, it deliberately sends at least two resizes so the application
is still forced to redraw.  See
[`server-client.c`](https://github.com/tmux/tmux/blob/c1f947a/server-client.c#L1949-L2005).
The relevant Tessera lesson is narrower: do not suppress an observed host
resize notification merely because the final character dimensions equal the
last model dimensions.  A direct terminal application would still have been
woken by `SIGWINCH`.  Tessera must either preserve separately observed size
changes or deliver one equivalent `SIGWINCH` to the child PTY foreground
process group when a coalesced host notification has the same final
`winsize`.  It must not invent an intermediate geometry it did not observe.

tmux falls back to 80x24 for zero/missing character dimensions and may issue
xterm size queries to obtain pixel data; see
[`tty.c`](https://github.com/tmux/tmux/blob/c1f947a/tty.c#L124-L159).  Neither
behavior transfers to Tessera's transparent proxy.  The proxy must not emit
queries or synthetic replies; it forwards the raw host `winsize` to the child,
but retains the last valid renderer geometry if rows or columns cannot form a
`Size.t`.

## Architecture and state boundaries

tmux documents its own fundamental flow as PTY bytes parsed into a virtual
screen and later translated back into terminal escape sequences; see
[`window.c`](https://github.com/tmux/tmux/blob/c1f947a/window.c#L40-L48).
Its `input.c` parser directly issues mutable `screen_write_*` calls.  This is
useful confirmation that parsing, screen semantics, and terminal emission are
distinct jobs, but it is not a model for Tessera's API.

Tessera keeps the stronger boundaries:

- Decoder: bytes to ordered semantic updates/effects, with no renderer state.
- Renderer: pure updates to immutable state, patches, and snapshots.
- Encoder/Repaint: optional controlled-output path only.
- Transparent proxy: forwards original bytes and never substitutes its
  renderer/encoder output for them.

The difference is material.  tmux can redraw after discarding output because
it owns a screen model and terminal output.  Tessera may compact or drop slow
observer data, but may never discard, delay indefinitely, or re-encode either
terminal byte direction.

## Backpressure

tmux's TTY output buffer has a `TTY_BLOCK` mode which drains queued terminal
output when a client cannot keep up and schedules a redraw; see
[`tty.c`](https://github.com/tmux/tmux/blob/c1f947a/tty.c#L219-L255) and
[`tty.c`](https://github.com/tmux/tmux/blob/c1f947a/tty.c#L629-L645).

That is correct for tmux's owned-renderer model, but forbidden for Tessera's
transparent relay.  Tessera's terminal relay must use normal bounded
write-queue/backpressure handling without changing byte order or content.  Its
observer channel may be lossy only by emitting an explicit gap and requiring a
fresh snapshot.

## Terminfo and terminal probing

tmux loads terminfo through the host curses implementation (`setupterm` and
`tigetstr` in
[`tty-term.c`](https://github.com/tmux/tmux/blob/c1f947a/tty-term.c#L721-L751))
and issues feature and size queries to the controlled terminal.  This confirms
the practical value of terminfo capability selection, but neither mechanism is
portable or pure enough for Tessera's core.

Tessera therefore retains its in-tree, bounded terminfo parser and adapter-only
resource discovery.  It also retains the rule that a transparent proxy neither
adds terminal probes nor fabricates their replies.  Any application-issued
query remains original relayed traffic and is only observed/classified.

## Decisions retained after review

| Concern | Tessera decision |
| --- | --- |
| Host resize source | Re-query the host TTY after a wake-up; do not encode size as terminal input bytes. |
| Child notification | Apply full `winsize` with `TIOCSWINSZ`; preserve a same-size observed resize notification rather than silently losing it. |
| Model event | Feed a portable geometry update through the serial session ingress; record it explicitly for observers. |
| Pixel dimensions | Preserve them on the PTY and expose them as proxy metadata; do not make them part of the character-cell renderer. |
| Original traffic | Forward byte-for-byte.  tmux's re-emission and redraw recovery are out of scope. |
| Observer backpressure | Drop only observer records with an explicit gap and snapshot recovery. |
| Queries | Do not inject probes or replies in transparent mode. |
| Terminal description | Parse supplied/bundled terminfo in the portable core; do not use host curses as a core dependency. |
