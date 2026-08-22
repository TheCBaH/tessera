# Controlled capability-program subset

Tessera does not evaluate arbitrary terminfo programs. A capability is parsed
once into a finite program of literals and the operations listed below. Any
other percent operation makes the corresponding update unexpressible before
the adapter writes bytes.

| Source operation | Program operation | Meaning |
| --- | --- | --- |
| '%%' | literal percent | Emit '%'. |
| '%p1' | first parameter | Select the first integer parameter. |
| '%p2' | second parameter | Select the second integer parameter. |
| '%d' | decimal | Emit the selected parameter in base ten. |
| '%i' | increment | Increment the first two parameters before later selection. |

There are deliberately no variables, constants, arithmetic, conditionals,
string arguments, or indirect operations. This makes evaluation bounded,
deterministic, and independent of a general terminfo interpreter.

The encoder validates the complete emitted control sequence against the
'max_control_bytes' policy limit; repeated single-step capabilities are also
bounded by that total limit. An empty repeated capability is rejected.

## Release-one update mapping

The controlled encoder accepts only the following updates:

| Update | Terminfo capability |
| --- | --- |
| Reset; erase display clear-all | 'clear' |
| Erase line clear-right | 'el' |
| Erase characters | 'ech' with one integer parameter |
| Move cursor position | 'cup' with row then column parameters |
| Move cursor up/down/back/forward | 'cuu1'/'cud1'/'cub1'/'cuf1', repeated |
| Print | Direct UTF-8 grapheme bytes |

Every other model update is reported as unexpressible. This keeps controlled
output constrained to the capability subset Repaint can currently produce.

## Repaintable projection

The release-one controlled projection is deliberately narrower than the
decoder/renderer model. It accepts primary-screen, visible-cursor,
default-style cells and cursor presentation only. Alternate-screen, hidden
cursor, title, and non-default cell or cursor styles are rejected by
Repaint.compile before it returns an update batch. A full refresh starts with
the clear capability, then writes the active screen's complete physical
projection and restores the cursor position.
