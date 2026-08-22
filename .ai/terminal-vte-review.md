# Tessera: VTE implementation review

This is a comparator review, not a proposed dependency. It is separate because
VTE is the terminal-emulation library used beneath GNOME Terminal; the GNOME
Terminal application source does not implement this decoder itself.

Review basis: VTE commit
[`1f53b48`](https://github.com/GNOME/vte/tree/1f53b48) (cloned from
`https://github.com/GNOME/vte.git` on 2026-08-22).

## Emulator family

VTE's parser calls itself DEC VT100+ compatible and states that its state
machine is fully compatible through the VT500 series, while requiring UCS-4
input after the caller has decoded UTF-8. See
[`parser.hh`](https://github.com/GNOME/vte/blob/1f53b48/src/parser.hh#L341-L375).
That is a broad DEC/ECMA framing baseline, not an exact promise to emulate a
single historic device. The library also maps recognised syntax through its
own command tables and terminal operations, which include later compatibility
extensions.

## Decode, frame, then dispatch

Incoming child bytes enter `Terminal::feed`, are queued in chunks, and are
processed by an incremental UTF-8 decoder. Invalid input is reset and becomes
U+FFFD; accepted code points are passed to the control-sequence state machine.
See
[`vte.cc`](https://github.com/GNOME/vte/blob/1f53b48/src/vte.cc#L4153-L4196)
and
[`Terminal::feed`](https://github.com/GNOME/vte/blob/1f53b48/src/vte.cc#L4799-L4825).

The parser recognises graphic characters, controls, ESC, CSI, DCS, OSC, SCI,
APC, PM, and SOS as distinct syntactic sequence kinds. It keeps explicit
states for ground, ESC/CSI/DCS/OSC parsing and unsupported strings, while
collecting parameters, intermediates, and strings. See
[`parser.hh`](https://github.com/GNOME/vte/blob/1f53b48/src/parser.hh#L31-L53)
and
[`parser.hh`](https://github.com/GNOME/vte/blob/1f53b48/src/parser.hh#L341-L470).

The terminal then dispatches recognised commands through an explicit command
switch into screen operations, rather than having the framer mutate the screen
directly; see
[`vte.cc`](https://github.com/GNOME/vte/blob/1f53b48/src/vte.cc#L4218-L4310).

## Deliberate parsing-policy choices

The source documents several choices that are not universal terminal protocol:
it accepts colon-separated CSI subparameters, permits BEL as an OSC terminator
as a deprecated xterm extension, and treats C0 controls differently inside
CSI, OSC, and DCS payloads. See
[`parser.hh`](https://github.com/GNOME/vte/blob/1f53b48/src/parser.hh#L210-L235)
and
[`parser.hh`](https://github.com/GNOME/vte/blob/1f53b48/src/parser.hh#L730-L826).

The transferable design lesson is to specify those recovery and termination
rules explicitly. A parser can share broad ECMA/DEC framing with another
emulator yet diverge materially on malformed input, string controls, and
extended parameters.
