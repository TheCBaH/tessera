# Tessera: GNOME Terminal implementation review

This is a comparator review, not a proposed dependency. It records what the
GNOME Terminal application layer makes visible about resize, presentation, and
PTY ownership.

Review basis: GNOME Terminal commit
[`5ba7dfb`](https://github.com/GNOME/gnome-terminal/tree/5ba7dfb) (cloned from
`https://github.com/GNOME/gnome-terminal` on 2026-08-22).

## The application layer delegates terminal emulation

The application creates and configures a `VteTerminal`, including setting its
initial character-grid size; see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L1188-L1205).
This repository therefore provides useful application and integration evidence,
but VTE, rather than this application, owns many emulator and PTY details.
Those details must not be inferred as GNOME Terminal behavior without reviewing
the VTE source separately.

## Control-stream decoder boundary

GNOME Terminal does not contain a VT control-sequence parser. Its screen type
inherits from `VteTerminal` (see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L405-L420)),
and it delegates child spawning and the attached PTY to that widget. The one
local `vte_terminal_feed` call supplies a sanitised, application-created title
sequence, rather than decoding child output; see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L1206-L1224).

Consequently, the terminal family and control-character behavior visible in a
GNOME Terminal window are VTE behavior, subject to its version and profile
configuration. The matching source-level decoder analysis is kept separately
in `terminal-vte-review.md`; it must not be described as an implementation of
the GNOME Terminal UI layer.

## Character grid and cell metrics are distinct

The UI obtains terminal rows and columns independently from the character
width and height when presenting size information; see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L2827-L2847).
Its allocation handling also detects when an allocation produces a changed
row/column grid; see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L785-L818).

This supports an adapter boundary that waits for stable toolkit layout and
reports validated character cells as the controlling geometry. Pixel values
are presentation metadata, not substitutes for the PTY grid.

## Rewrap is an explicit presentation policy

The profile setting `rewrap-on-resize` is applied through the terminal widget;
see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L1547-L1566).
That is evidence that resize reflow is a deliberate user/session policy,
rather than a universal terminal protocol requirement. A transparent observer
must make its own policy explicit and preserve its documented snapshot
semantics.

## PTY and process ownership remain below the UI

The application obtains a terminal PTY from the widget and uses foreground
process-group information when managing a running command; see
[`terminal-screen.cc`](https://github.com/GNOME/gnome-terminal/blob/5ba7dfb/src/terminal-screen.cc#L2948-L2971).
For Tessera, this reinforces separating toolkit layout from the native PTY
adapter: the latter is responsible for applying grid geometry and delivering
the documented application-facing notification, while the portable core sees
only ordered semantic input.
