# Tessera core: first implementation increment

## Deliverable

This increment implements one portable, pure Dune library named tessera. It
accepts serialised semantic ingress for a fixed xterm-256color core profile:
fragmented application-output byte slices and explicit validated resize
notifications. It produces:

- an explicit decoder continuation;
- ordered semantic updates and bounded diagnostics;
- an immutable logical screen state;
- precise screen damage and a cell snapshot.

The deliverable ends at the pure core boundary. It is buildable and tested on native OCaml, js_of_ocaml, and Melange. The fixed profile is a typed value, not parsed configuration data. The core has no scheduler, PTY, signal, browser-layout, or observer-wire dependency: an adapter turns those host concerns into the serial ingress vocabulary.

The package name is `tessera`; the public OCaml namespace is `Tessera`.

The supported semantic slice is UTF-8 text; C0 controls; ESC save/restore, index, reverse index, next line, tab set, and reset; CSI cursor movement/positioning, erase, insert/delete characters and lines, scrolling, margins, SGR, and selected DEC modes; alternate screen and cursor visibility; OSC 0/2 title; and framing/diagnostics for OSC, DCS, APC, and PM strings. It preserves parser synchronisation for all other framed sequences.

## Source layout

    tessera/
      dune-project
      lib/
        foundation/
          dune                       # tessera_foundation
          byte_offset.ml byte_offset.mli
          generation.ml generation.mli
          id.ml id.mli
          line_id.ml line_id.mli
          lineage_id.ml lineage_id.mli
          types.ml types.mli
          uint.ml uint.mli
          uint64.ml uint64.mli
          limits.ml limits.mli
          policy.ml policy.mli
        model/
          dune                       # tessera_model
          style.ml style.mli
          mode.ml mode.mli
          unicode.ml unicode.mli
          cell.ml cell.mli
          collection.ml collection.mli
          update.ml update.mli
          effect.ml effect.mli
        terminfo/                   # second increment: tessera_terminfo
          dune
          capability.ml capability.mli
          description.ml description.mli
        encoder/                    # second increment: tessera_encoder
          dune
          encoder.ml encoder.mli
        decoder/
          dune                       # tessera_decoder
          decode_state.ml decode_state.mli
          decoder.ml decoder.mli
        renderer/
          dune                       # tessera_renderer
          grid.ml grid.mli
          state.ml state.mli
          patch.ml patch.mli
          renderer.ml renderer.mli
        repaint/                    # second increment: tessera_repaint
          dune
          target.ml target.mli
          repaint.ml repaint.mli
        core/
          dune                       # public library: tessera
          session.ml session.mli
          tessera.ml tessera.mli
      test/
        support/
          dune
          pp.ml pp.mli
          fixture.ml fixture.mli
        model/
          dune
          collections.ml
          ids.ml
          policy.ml
          unicode.ml
        decoder/
          dune
          c0_esc.ml
          csi.ml
          strings.ml
          chunking.ml
          corpus/
        renderer/
          dune
          cursor.ml
          editing.ml
          scrolling.ml
          styles.ml
          screens.ml
          invariants.ml
          allocation.ml
        repaint/                    # second increment
          dune
          compiler.ml
          target.ml
        terminfo/                   # second increment
          dune
          compiled.ml
          source.ml
        encoder/                    # second increment
          dune
          encoding.ml
        core/
          dune
          session.ml
          patch.ml
          composition.ml
        integration/
          dune
          conformance.ml
        fixtures/
          decoder/
          renderer/
          core/
      bench/
        renderer/
          dune
          renderer_bench.ml
          renderer_memtrace.ml

Each component directory is a separate wrapped Dune library. Its dune stanza declares only lower-layer libraries, so Dune prevents Decoder from importing Renderer and Renderer from importing Decoder. The public Tessera library in lib/core aliases the intended API as Tessera.Types, Tessera.Decoder, Tessera.Renderer, Tessera.Patch, and Tessera.Session. Grid, State, and Decode_state stay internal to their component libraries; the public facade exposes snapshots, patches, and continuations only through the documented component interfaces.

## Build dependencies

The library has four runtime dependencies:

| Dependency | Use |
| --- | --- |
| OCaml standard library | bytes, immutable collections, Format printers, Uchar, Int64, and Result. |
| err_trace | Typed errors and bounded provenance through the Err module. |
| Vendored uutf | Upstream UTF-8 codec source, compiled by the local Dune overlay. |
| Vendored uuseg and uucp | Upstream grapheme segmentation and character-property source used by width calculation, compiled from the same submodules for every portable target. |

The test profile adds ppx_expect, Alcotest, QCheck, benchmark, and memtrace. The core library has no Unix, scheduler, filesystem, JavaScript-binding, or C-stub dependency.

## Module catalogue

| Source module | Public type/value boundary | Depends on |
| --- | --- | --- |
| UInt | opaque non-negative portable `int`, checked conversion/arithmetic, and comparison | Stdlib |
| UInt64 | private non-negative `Int64` representation for values that may exceed portable `int` range | Int64 |
| Id | generic phantom-typed opaque identifier, same-kind equality/comparison, and an internal checked `int` representation | UInt |
| Byte_offset | opaque, non-negative stream offset and checked addition | UInt64 |
| Generation | `Generation.tag Id.t`, monotonically increasing renderer revision token, and successor only | Id |
| Line_id | `Line_id.tag Id.t`, logical-line identity and successor only | Id |
| Lineage_id | `Lineage_id.tag Id.t`, explicit renderer-lineage identifier | Id |
| Types | opaque Column, Row, and positive Size values; coord, rect, screen = Alternate or Primary, slice, and range-checked constructors | UInt |
| Limits | finite maxima for input slice, CSI parameters, control-string bytes, diagnostics, rows, columns, and snapshot cells | Types, Err |
| Policy | validated limits plus fixed profile = Xterm_256color_core | Types, Limits |
| Style | color, rendition, style, default, and SGR application | Stdlib |
| Mode | origin, auto_wrap, insert, cursor_visible, and mode record | Types |
| Unicode | scalar, opaque ordered grapheme, width, decoder continuation, and feed/finish functions | Limits, Err, Uutf, Uuseg, Uucp |
| Cell | glyph, contents = Empty, Glyph, or Wide_continuation, and immutable cell | Line_id, Unicode, Style |
| Collection | canonical cell blocks/damage, immutable snapshot cells, and tab-stop set interfaces | Types |
| Terminfo (second increment) | capabilities, canonical capability map, description, and source/compiled parsers | Collection, Err, Limits, Types |
| Encoder (second increment) | capability-selected Update-to-byte compiler and typed unexpressible-operation errors | Policy, Terminfo, Update |
| Update | alphabetically ordered terminal operations, composable style/mode deltas, abstract batch, and normalize | Collection, Types, Style, Mode, Unicode |
| Effect | diagnostic kind, observation, and ordered item sequence | Collection, Types, Update |
| Patch | absolute cell replacements, presentation changes, canonical block/damage collections, and compose | Types, Cell, State, Effect, Err, Generation |
| Repaint (second increment) | controlled output target, Patch-to-Update compiler, and compiler errors | Description, Patch, Policy, Update |
| Grid | private persistent page map, get, set, map_rect, scroll, resize, and test statistics | Types, Cell |
| State | cursor, saved_cursor, buffer, screen_state, and whole terminal state | Collection, Generation, Line_id, Types, Grid, Mode, Style |
| Renderer | initial, apply, damage, snapshot, applied, patch production, and pure update semantics | Policy, Update, Effect, Patch, State, Grid, Cell, Unicode, Err |
| Decode_state | private byte-parser continuations and bounded accumulators | Types, Limits, Unicode |
| Decoder | initial, feed, finish, and decoded ordered items | Policy, Update, Effect, Decode_state, Unicode, Err |
| Session | initial, serial ingress, and finish composition boundary | Policy, Decoder, Renderer, State, Effect, Err |
| Tessera | narrow re-export facade: policy construction, session construction, ingest, finish, snapshot and printers | Session and public model modules |
| Pp | test-only stable printers for every public value | Tessera |
| Properties | QCheck generators and invariant checks | Tessera, QCheck |
| Allocation | native-only allocation and structural-sharing checks | Tessera, Gc, benchmark, memtrace |

No source module reaches upward: Decoder does not import Renderer or State, Renderer does not import Decoder, and Session is the sole composition module. Variants are listed alphabetically by constructor name and public record fields alphabetically by field name throughout this document. The ordering improves review and diff stability only; every operational ordering rule is stated separately.

## Data types

### Types, limits, and policy

    module UInt : sig
      type t = private int
      type error = [ `Negative of int | `Overflow ]
      module E : Err.S with type error = error
      val pp_error : Format.formatter -> error -> unit
      val add : t -> t -> (t, error) Err.t
      val max_value : t
      val of_int : int -> (t, error) Err.t
      val succ : t -> (t, error) Err.t
      val to_int : t -> int
    end

    module UInt64 : sig
      type t = private int64
      type error = [ `Negative of int64 | `Overflow ]
      module E : Err.S with type error = error
      val pp_error : Format.formatter -> error -> unit
      val add : t -> t -> (t, error) Err.t
      val of_int64 : int64 -> (t, error) Err.t
      val succ : t -> (t, error) Err.t
      val to_int64 : t -> int64
    end

    module Id : sig
      type 'kind t = private UInt.t
      val compare : 'kind t -> 'kind t -> int
      val equal : 'kind t -> 'kind t -> bool
    end

    module Byte_offset : sig type t end
    module Generation : sig
      type tag
      type t = tag Id.t
    end
    module Line_id : sig
      type tag
      type t = tag Id.t
    end
    module Lineage_id : sig
      type tag
      type t = tag Id.t
      val of_uint : UInt.t -> t
    end
    module Column : sig type t end
    module Row : sig type t end
    module Size : sig type t end

    type coord = { column : Column.t; row : Row.t }
    type rect = { bottom : Row.t; left : Column.t; right : Column.t; top : Row.t }
    type screen = Alternate | Primary
    type slice = { bytes : bytes; len : UInt.t; off : UInt.t }

`UInt` and `UInt64` are Tessera-owned modules, not OCaml Stdlib modules.
`UInt.t` is the project's portable unsigned/count type: it is an opaque,
non-negative `int`, with checked constructors and arithmetic. It deliberately
does not model a native unsigned machine word, whose size and semantics would
not agree across native OCaml, JSOO, and Melange. `UInt64.t` is reserved for a
long-lived stream position. `Id.t` is a generic phantom-typed identity over
the portable checked `UInt.t` representation: `Generation.t`, `Line_id.t`,
and `Lineage_id.t` are specialisations with distinct abstract tags, so they are
mutually non-interchangeable even when their internal counter representation
happens to be the same.

`Generation.t` is a monotonically increasing revision token for one renderer
state lineage. It is not a globally unique ID. `Lineage_id.t` is carried by
state, snapshots, and patches, and must be supplied when a renderer lineage is
initialised; an adapter may derive it from its own session identity and supply
the validated token through `Lineage_id.of_uint`. The core neither uses a
clock nor generates random IDs. `Line_id.t` is similarly only unique within
one renderer lineage. Generation and line counters fail with a typed
exhaustion error at `UInt.max_value`; a host establishes a new lineage/full
snapshot rather than allowing either identifier to wrap.

`Column.t` and `Row.t` are non-negative indexes. `Size.t` validates positive
row/column extents and provides checked containment/conversion operations;
callers cannot swap a row with a column or pass a negative `int`. `slice` is a
borrowed input view. Every public consumer validates its range before reading.
Decoder consumes a slice before returning and copies only the bounded bytes
required for a partial sequence.

    type limits =
      { max_columns : UInt.t
      ; max_control_bytes : UInt.t
      ; max_csi_params : UInt.t
      ; max_diagnostics : UInt.t
      ; max_rows : UInt.t
      ; max_slice_bytes : UInt.t
      ; max_snapshot_cells : UInt.t
      }

    type profile = Xterm_256color_core
    type t = { limits : limits; profile : profile }

Policy.make validates every positive dimension and every non-negative budget once. All decoder and renderer entry points receive the validated policy rather than individual limits.

Each component owns its own polymorphic-variant error payload and `Err.Make`
binding. For example:

    module Limits : sig
      type error = [ `Invalid_limit of { name : string; value : int } ]
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
    end

    module Decoder : sig
      type error =
        [ `Internal_invariant of string
        | `Invalid_slice
        | `Unicode of Unicode.error ]
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
    end

    module Renderer : sig
      type error = [ `Invalid_size | `Snapshot_limit_exceeded ]
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
    end

    module Session : sig
      type error = [ `Decode of Decoder.error | `Render of Renderer.error ]
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
    end

`Session.error` is an intentional composition boundary, not a registry. Other
components follow the same local pattern. Malformed terminal bytes are
observations, not `Decoder.error` values: a decoder error means the API could
not honour its own contract.

### Style, mode, Unicode, and cell

    module Palette_index : sig
      type t
      val pp : Format.formatter -> t -> unit
    end
    module Rgb : sig
      type t
      val pp : Format.formatter -> t -> unit
    end
    type color = Default | Indexed of Palette_index.t | Rgb of Rgb.t
    type rendition =
      { bold : bool; faint : bool; inverse : bool; invisible : bool
      ; italic : bool; strikethrough : bool; underline : bool }
    type style = { background : color; foreground : color; rendition : rendition }
    type 'a field = Keep | Set of 'a
    type delta =
      { background : color field
      ; bold : bool field
      ; faint : bool field
      ; foreground : color field
      ; inverse : bool field
      ; invisible : bool field
      ; italic : bool field
      ; strikethrough : bool field
      ; underline : bool field }

`Palette_index.t` validates the xterm palette range and `Rgb.t` validates the
three 0–255 channels; callers cannot smuggle a negative or over-range colour
component through a raw integer. Style.apply_sgr applies one validated SGR
parameter group to a style. Style.compose_delta combines two deltas as
later-after-earlier without requiring a starting style. The decoder emits
deltas; the renderer applies them to its current style.

    type mode =
      { auto_wrap : bool
      ; cursor_visible : bool
      ; insert : bool
      ; origin : bool }

    type scalar = Uchar.t
    type grapheme
    type width = One | Two | Zero

Unicode.feed consumes a decoded scalar and returns zero or more completed graphemes plus a new continuation. It preserves a bounded pending grapheme across calls; Unicode.finish flushes it at end of stream. Width uses the vendored Uucp data and the policy stated in terminal-idea.md: ambiguous width one, combining marks zero, and wide/emoji width two.

    type contents = Empty | Glyph of grapheme | Wide_continuation
    type t = { contents : contents; line_id : Line_id.t; style : Style.t }

A printable wide grapheme always creates a Glyph lead cell followed by Wide_continuation. Any edit touching either side clears or repairs the pair before proceeding.

### Updates and observations

    type cursor_move =
      | Back of UInt.t
      | Column of Column.t
      | Down of UInt.t
      | Forward of UInt.t
      | Next_line of UInt.t
      | Position of coord
      | Previous_line of UInt.t
      | Row of Row.t
      | Up of UInt.t

    type erase =
      | Display of [ `Clear_above | `Clear_all | `Clear_below ]
      | Line of [ `Clear_left | `Clear_line | `Clear_right ]

    type edit =
      | Delete_chars of UInt.t
      | Delete_lines of UInt.t
      | Erase_chars of UInt.t
      | Insert_chars of UInt.t
      | Insert_lines of UInt.t

    type margins = { bottom : Row.t; top : Row.t }

    type t =
      | Alternate_screen of [ `Enter_1049 | `Leave_1049 ]
      | Backspace
      | Carriage_return
      | Edit of edit
      | Erase of erase
      | Horizontal_tab
      | Line_feed
      | Move_cursor of cursor_move
      | Print of Unicode.Grapheme_sequence.t
      | Reset
      | Resize of Size.t
      | Restore_cursor
      | Save_cursor
      | Scroll_down of UInt.t
      | Scroll_up of UInt.t
      | Set_margins of margins
      | Set_mode of Mode.delta
      | Set_style of Style.delta
      | Set_tab
      | Set_title of string
      | Switch_screen of screen

    module Batch : sig type t end

    type diagnostic =
      | Control_string_too_long of { kind : string; offset : Byte_offset.t }
      | Invalid_utf8 of { offset : Byte_offset.t }
      | Malformed_csi of { offset : Byte_offset.t; reason : string }
      | Unsupported_sequence of { family : string; offset : Byte_offset.t }

    type observation =
      | Diagnostic of diagnostic
      | Resize of Size.t

    type item = Observation of observation | Update of Update.t

Decoder returns `Effect.Item_sequence.t` in byte-stream order, emitting only
`Diagnostic` observations. Session retains those ordered items in its outcome
for diagnostics and tests, and adds a `Resize` observation when it accepts an
out-of-band resize ingress. `Unicode.Grapheme_sequence.t` is similarly an
ordered, duplicate-preserving sequence: scalar order is part of a grapheme, so
it is not a set/map or a publicly mutable array.

Update.Batch.normalize is a sequence-only, semantics-preserving canonicaliser.
It merges adjacent printable grapheme sequences and composes adjacent Set_style
and Set_mode deltas. It retains cursor-relative movement, edit, erase, scroll,
margin, screen, reset, resize, and title operations in order because their
meaning can depend on the renderer state. In particular, a resize is never
removed merely because its `Size.t` equals the current geometry: a
session-induced resize notification is an observable full-projection refresh.
A normalised batch is equivalent to the original batch for every valid renderer
state.

### Collection boundaries

Collections are exposed by their owning module, rather than as raw standard
collections with undocumented laws:

    module Unicode : sig
      module Grapheme_sequence : sig type t end
    end
    module Update : sig
      module Batch : sig type t end
    end
    module Effect : sig
      module Item_sequence : sig type t end
      module Observation_sequence : sig type t end
    end

    module Collection : sig
      module Cell_block : sig type t end
      module Cell_blocks : sig type t end
      module Damage : sig type t end
      module Snapshot_cells : sig type t end
      module Tab_stops : sig type t end
    end

    module Description : sig
      module Capability_map : sig type t end
    end

`Grapheme_sequence`, `Batch`, and the two effect sequences are ordered and may
contain repeated elements; their public `append` is left-then-right. A
`Cell_blocks.t` is instead a canonical collection of disjoint physical regions,
and `Damage.t` is a canonical rectangle union. `Tab_stops.t` is a set of
columns. `Capability_map.t` provides unique-key lookup. Each module offers
canonical enumeration and purpose-specific combination; it does not inherit an
accidental list/set/map union rule.

### Patch

Patch is the state-independent output language for observers and batching. Renderer, not Decoder, produces it after resolving terminal operations against state.

    type 'a change = Keep | Set of 'a
    type presentation =
      { active : screen change
      ; cursor : cursor change
      ; cursor_visible : bool change
      ; title : string option change }
    type t =
      { after_generation : Generation.t
      ; before_generation : Generation.t
      ; before_size : Size.t
      ; cells : Collection.Cell_blocks.t
      ; damage : Collection.Damage.t
      ; lineage_id : Lineage_id.t
      ; observations : Effect.Observation_sequence.t
      ; presentation : presentation
      ; size : Size.t change }

`Collection.Cell_block.t` has one `Cell.t` value for every physical cell in its
area, in row-major order, but exposes enumeration rather than a mutable OCaml
array. `Collection.Cell_blocks.t` is a canonical collection of disjoint blocks
sorted by screen, row, and column; a height-one block is a row run. Cell
replacements are absolute values, including blank cells. Patch.normalize
applies last-writer-wins to duplicate coordinates, compacts adjacent compatible
replacements into maximal row runs and rectangles, and normalises damage
rectangles.

Every patch produced for `Update.Resize` has `size = Set resulting_size`, even
when `resulting_size` equals the prior size. It carries the complete resulting
physical projection and full damage. This makes a resize record and refresh
unambiguous to an observer; it is not an inferred side effect of a geometry
comparison.

Patch.compose left right accepts only equal lineage IDs and an adjacent
generation chain. It overlays right cell blocks on left cell blocks; right
presentation fields replace left fields when set; and observations are appended
in order. A right patch with `size = Set _` is a full-projection barrier: it
discards left cell replacements and damage, including for a same-geometry
resize. The result has left.before_generation, right.after_generation, and
exactly the same resulting projection as applying left then right to a consumer
projection. Composition reads no Renderer.state or Grid.t.

### Repaint: Patch → updates → encoded bytes (second increment)

`Tessera.Repaint` is the output-rendering companion to the logical renderer.
It is deliberately separate from both `Renderer.apply` (which interprets
updates into a model) and `Encoder.encode` (which serialises updates into
control-character bytes):

    Patch.t ──► Repaint.compile ──► Update.Batch.t ──► Encoder.encode ──► bytes
                  │                                          │
                  └─► next Target.t                          └─► owned terminal

    type error =
      [ `Generation_mismatch
      | `Incomplete_wide_pair
      | `Lineage_mismatch
      | `Unsupported_attachment
      | `Unsupported_observation
      | `Unsupported_presentation ]

    type target

    val compile : Description.t -> Policy.t -> target -> Patch.t
      -> (target * Update.Batch.t, error) Err.t

`target` is an opaque, persistent projection of the *owned output terminal*:
its lineage/generation, geometry, cursor/style/mode baseline, and visible
cells. It is not `Renderer.state`, and it is never used by the transparent
proxy. Compilation checks the patch lineage and predecessor generation, applies
the absolute cell/presentation changes to the target projection, then emits a
canonical update sequence using only capabilities present in the supplied
description. The application passes that sequence unchanged to
`Encoder.encode description policy` and writes the resulting byte chunks in
order.

A sparse patch is unsafe after an output-terminal disconnect or any unknown
write failure. In that case the caller discards `target`, establishes the
documented canonical terminal baseline, obtains a full patch/snapshot, and
compiles a full repaint. Tests must prove that compiling an adjacent patch
chain updates the controlled target exactly as a reference application of the
absolute patch does; that a generation/lineage mismatch writes no bytes; and
that a controlled round trip preserves the normalised requested patch.  That
round trip starts the reference decoder/renderer and `Repaint.target` from the
same canonical pre-patch projection, then executes:

    Patch.t → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply

For the repaintable subset, its resulting `Patch.normalize` and successor
screen projection equal the original normalised patch and projection. The
subset excludes unsupported capabilities, attachments, observations, and any
unknown output-terminal mutation. This is intentionally not a byte round trip:
the encoder may choose a different, equivalent control-sequence spelling from
the bytes that originally decoded to the patch.

### Grid, state, renderer result

Grid uses pages of 32 columns by 8 rows. A page is an immutable Cell.t array. The grid maps page coordinates to pages and treats absent pages as a shared blank page. set copies one page, not the full screen.

    type cursor = { pending_wrap : bool; position : coord; style : Style.t }
    type saved_cursor = { origin : bool; position : coord; style : Style.t }
    type buffer =
      { cursor : cursor
      ; grid : Grid.t
      ; margins : margins
      ; saved : saved_cursor option
      ; tabs : Collection.Tab_stops.t }

    type state =
      { active : screen
      ; alternate : buffer
      ; generation : Generation.t
      ; lineage_id : Lineage_id.t
      ; modes : Mode.t
      ; next_line_id : Line_id.t
      ; primary : buffer
      ; title : string option }

    type damage =
      { cursor_changed : bool; full : bool; rects : Collection.Damage.t }
    type snapshot =
      { active : screen
      ; cells : Collection.Snapshot_cells.t
      ; cursor : cursor
      ; cursor_visible : bool
      ; generation : Generation.t
      ; lineage_id : Lineage_id.t
      ; size : Size.t
      ; title : string option }

    type applied =
      { damage : damage
      ; observations : Effect.Observation_sequence.t
      ; patch : Patch.t
      ; snapshot : snapshot
      ; state : state }

Renderer.apply handles the batch left to right. It clamps cursor motions to the active margins, performs autowrap before a printable cell when pending_wrap is true, scrolls within margins, and marks the smallest affected rectangle. Resize changes the physical size without reflow; it clips cells and clamps margins/cursor when needed. Every accepted resize is a generation-advancing transition, including one to the current size, and returns a full-damage patch and complete snapshot projection.

### Decoder continuation and session

    type parser =
      | Csi of csi_accumulator
      | Discard_string of discard_accumulator
      | Escape
      | Ground
      | String of string_accumulator

    type continuation =
      { byte_offset : Byte_offset.t
      ; diagnostics_left : UInt.t
      ; parser : parser
      ; utf8 : Unicode.decoder_continuation }

    type decoded =
      { continuation : continuation; items : Effect.Item_sequence.t }

    type byte_input = Types.slice
    type out_of_band = Resize of Size.t
    type input = Bytes of byte_input | Out_of_band of out_of_band

    type session =
      { decoder : Decoder.continuation
      ; policy : Policy.t
      ; renderer : Renderer.state }

    type outcome =
      { damage : Renderer.damage
      ; items : Effect.Item_sequence.t
      ; patch : Patch.t
      ; session : session
      ; snapshot : Renderer.snapshot }

`Session.ingest` is one total, synchronous transition over exactly one input.
For `Bytes slice`, it calls `Decoder.feed`, extracts updates in item order, and
calls `Renderer.apply` exactly once. For `Out_of_band (Resize size)`, it does
not decode or forward bytes: it applies a singleton `Update.Resize size`, emits
one ordered `Observation (Resize size)`, and returns the resulting full-damage
patch and snapshot. It performs that transition even when `size` equals the
renderer geometry. Its `snapshot` and `patch` fields are pass-through renderer
outputs; Session does not construct either. The returned session is the only
state needed for the next call.

`Session.finish` is the explicit end-of-byte-stream transition. It calls
`Decoder.finish`, applies its remaining updates once, and returns their ordered
diagnostics and projection. EOF is not represented by a synthetic terminal
update or an `out_of_band` constructor. A checkpoint may be taken only between
completed `ingest` or `finish` calls.

### Checkpoint boundary and serialisation

`Checkpoint.V1` is the portable-core checkpoint contract. Its canonical,
length-delimited codec contains exactly a format version, the canonical policy
value, decoder continuation, and renderer state. It is constructed only from a
completed `Session.t`: the value returned by `initial` or by `successor` after
a successful `ingest` or `finish`. It never represents a borrowed byte slice,
an input in progress, or an unobserved partial outcome. The codec rejects an
unknown version, malformed field length, duplicate or missing field, and any
restored value that violates the restored policy limits; it is not an OCaml
`Marshal` payload.

The core payload deliberately excludes terminal-description identity and
observer sequence positions, because Session neither selects a description nor
owns observers. A proxy may wrap `Checkpoint.V1` in its own versioned envelope
containing those two identities. Signals, file descriptors, tasks/promises,
process or adapter lifecycle state, borrowed buffers, pixel geometry, and CSS
measurements are invalid in both forms. Restoring a core checkpoint performs no
I/O; an adapter re-establishes its host resources before it resumes ingress.

The portable `out_of_band` vocabulary contains only events with a deterministic
core transition. It does not expose signals, descriptor readiness, cancellation,
process exit, observer disconnect, pixels, or browser CSS measurements. An
adapter validates positive character rows/columns and serialises the resulting
input with byte ingress in its observed dequeue order. Pixel geometry and its
unit, raw host notifications, PTY ioctls, and lifecycle errors remain adapter
or observer-protocol data; they never enter a portable checkpoint.

The ordering contract is deliberately local: bytes already passed to `ingest`
precede a later resize; an adapter chooses and preserves an order for inputs
ready together. A Linux proxy processes a pending resize before previously
unread child output, while a browser adapter enqueues each completed-layout
callback through the same boundary. Distinct validated callbacks retain their
order. A coalesced host notification contributes only the geometry the adapter
actually re-queries or receives; the core never invents a missing intermediate
size.

## Core component signatures

These are the proposed stable public `.mli` boundaries. They omit parser FSM
tables and persistent-grid pages, which remain private implementation details.
All functions are pure; expected failures return the corresponding
`('a, error) Err.t` domain value rather than exceptions.

Each `module E : Err.S with type error = error` below is implemented locally
as `module Error = struct type nonrec error = error let pp_error = pp_error
end` followed by `module E = Err.Make(Error)`. These are component-local
domains, not registrations in a global error module.

Every public module supplies deterministic `pp` functions for its public
values. `pp` prints the module's principal type; modules with several public
types use `pp_<type>`. Printers have no colour, no memory addresses, no
`err_trace` provenance, and no unbounded implicit dump: opaque continuations,
states, and large collections print a stable summary unless an explicit bounded
iterator/printer is requested. Error-domain printers remain named `pp_error`,
which is the printer bound through `Err.Make`.

### Foundation

    module UInt : sig
      type t = private int
      type error = [ `Negative of int | `Overflow ]
      module E : Err.S with type error = error
      val pp_error : Format.formatter -> error -> unit
      val add : t -> t -> (t, error) Err.t
      val compare : t -> t -> int
      val equal : t -> t -> bool
      val max_value : t
      val of_int : int -> (t, error) Err.t
      val pp : Format.formatter -> t -> unit
      val succ : t -> (t, error) Err.t
      val to_int : t -> int
    end

    module UInt64 : sig
      type t = private int64
      type error = [ `Negative of int64 | `Overflow ]
      module E : Err.S with type error = error
      val pp_error : Format.formatter -> error -> unit
      val add : t -> t -> (t, error) Err.t
      val compare : t -> t -> int
      val equal : t -> t -> bool
      val of_int64 : int64 -> (t, error) Err.t
      val pp : Format.formatter -> t -> unit
      val succ : t -> (t, error) Err.t
      val to_int64 : t -> int64
    end

    module Id : sig
      type 'kind t = private UInt.t
      val compare : 'kind t -> 'kind t -> int
      val equal : 'kind t -> 'kind t -> bool
      val pp : Format.formatter -> 'kind t -> unit
    end

    module Byte_offset : sig
      type t
      val add : t -> UInt.t -> (t, UInt64.error) Err.t
      val compare : t -> t -> int
      val equal : t -> t -> bool
      val pp : Format.formatter -> t -> unit
      val zero : t
    end

    module Generation : sig
      type tag
      type t = tag Id.t
      val compare : t -> t -> int
      val equal : t -> t -> bool
      val pp : Format.formatter -> t -> unit
    end

    module Line_id : sig
      type tag
      type t = tag Id.t
      val compare : t -> t -> int
      val equal : t -> t -> bool
      val pp : Format.formatter -> t -> unit
    end

    module Lineage_id : sig
      type tag
      type t = tag Id.t
      val compare : t -> t -> int
      val equal : t -> t -> bool
      val of_uint : UInt.t -> t
      val pp : Format.formatter -> t -> unit
    end

    module Types : sig
      type error = [ `Invalid_rect | `Invalid_size | `Invalid_slice ]
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      module Column : sig
        type t
        val compare : t -> t -> int
        val of_uint : UInt.t -> t
        val pp : Format.formatter -> t -> unit
      end
      module Row : sig
        type t
        val compare : t -> t -> int
        val of_uint : UInt.t -> t
        val pp : Format.formatter -> t -> unit
      end
      type coord = { column : Column.t; row : Row.t }
      type rect
      type screen = Alternate | Primary
      type slice
      module Size : sig
        type t
        val columns : t -> UInt.t
        val contains : t -> coord -> bool
        val make : columns:UInt.t -> rows:UInt.t -> (t, error) Err.t
        val pp : Format.formatter -> t -> unit
        val rows : t -> UInt.t
      end
      val coord : column:Column.t -> row:Row.t -> coord
      val pp_coord : Format.formatter -> coord -> unit
      val pp_rect : Format.formatter -> rect -> unit
      val pp_screen : Format.formatter -> screen -> unit
      val pp_slice : Format.formatter -> slice -> unit
      val rect : bottom:Row.t -> left:Column.t -> right:Column.t -> top:Row.t
        -> (rect, error) Err.t
      val slice : bytes -> len:UInt.t -> off:UInt.t
        -> (slice, error) Err.t
    end

    module Limits : sig
      type error = [ `Invalid_limit of { name : string; value : int } ]
      type t
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      val make : max_columns:UInt.t -> max_control_bytes:UInt.t
        -> max_csi_params:UInt.t -> max_diagnostics:UInt.t
        -> max_rows:UInt.t -> max_slice_bytes:UInt.t
        -> max_snapshot_cells:UInt.t -> (t, error) Err.t
      val pp : Format.formatter -> t -> unit
    end

    module Policy : sig
      type profile = Xterm_256color_core
      type t
      val limits : t -> Limits.t
      val make : limits:Limits.t -> profile:profile -> t
      val pp : Format.formatter -> t -> unit
      val pp_profile : Format.formatter -> profile -> unit
      val profile : t -> profile
    end

`Generation` and `Line_id` have no public constructors; only renderer
transitions mint them. `Lineage_id.of_uint` is the sole identity-import
point, so adapters—not the pure core—own session-domain uniqueness.

### Model

    module Style : sig
      type color
      type delta
      type t
      module Palette_index : sig
        type t
        val pp : Format.formatter -> t -> unit
      end
      module Rgb : sig
        type t
        val pp : Format.formatter -> t -> unit
      end
      val apply_delta : t -> delta -> t
      val compose_delta : earlier:delta -> later:delta -> delta
      val default : t
      val empty_delta : delta
      val pp : Format.formatter -> t -> unit
      val pp_color : Format.formatter -> color -> unit
      val pp_delta : Format.formatter -> delta -> unit
    end

    module Mode : sig
      type delta
      type t
      val apply_delta : t -> delta -> t
      val compose_delta : earlier:delta -> later:delta -> delta
      val default : t
      val empty_delta : delta
      val pp : Format.formatter -> t -> unit
      val pp_delta : Format.formatter -> delta -> unit
    end

    module Unicode : sig
      type decoder_continuation
      type error = [ `Invalid_utf8 | `Unicode_limit_exceeded ]
      type grapheme
      type scalar = Uchar.t
      type width = One | Two | Zero
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      module Grapheme_sequence : sig
        type t
        val append : t -> t -> t
        val empty : t
        val fold_left : ('a -> grapheme -> 'a) -> 'a -> t -> 'a
        val pp : Format.formatter -> t -> unit
      end
      val feed : Policy.t -> decoder_continuation -> scalar
        -> (decoder_continuation * Grapheme_sequence.t, error) Err.t
      val finish : Policy.t -> decoder_continuation
        -> (Grapheme_sequence.t, error) Err.t
      val initial : decoder_continuation
      val pp_decoder_continuation : Format.formatter -> decoder_continuation -> unit
      val pp_grapheme : Format.formatter -> grapheme -> unit
      val pp_scalar : Format.formatter -> scalar -> unit
      val pp_width : Format.formatter -> width -> unit
      val width : grapheme -> width
    end

    module Cell : sig
      type contents = Empty | Glyph of Unicode.grapheme | Wide_continuation
      type t
      val blank : line_id:Line_id.t -> style:Style.t -> t
      val contents : t -> contents
      val line_id : t -> Line_id.t
      val pp : Format.formatter -> t -> unit
      val pp_contents : Format.formatter -> contents -> unit
      val style : t -> Style.t
    end

    module Collection : sig
      module Cell_block : sig
        type t
        val pp : Format.formatter -> t -> unit
      end
      module Cell_blocks : sig
        type t
        val empty : t
        val fold_left : ('a -> Cell_block.t -> 'a) -> 'a -> t -> 'a
        val normalize : t -> t
        val pp : Format.formatter -> t -> unit
      end
      module Damage : sig
        type t
        val empty : t
        val singleton : Types.rect -> t
        val union : t -> t -> t
        val pp : Format.formatter -> t -> unit
      end
      module Snapshot_cells : sig
        type t
        val get : t -> Types.coord -> Cell.t
        val pp : Format.formatter -> t -> unit
        val size : t -> Types.Size.t
      end
      module Tab_stops : sig
        type t
        val add : t -> Types.Column.t -> t
        val empty : t
        val mem : t -> Types.Column.t -> bool
        val pp : Format.formatter -> t -> unit
        val remove : t -> Types.Column.t -> t
      end
    end

    module Update : sig
      type t
      type operation = t
      module Batch : sig
        type t
        val append : t -> t -> t
        val empty : t
        val fold_left : ('a -> operation -> 'a) -> 'a -> t -> 'a
        val normalize : t -> t
        val pp : Format.formatter -> t -> unit
        val singleton : operation -> t
      end
      val pp : Format.formatter -> t -> unit
    end

    module Effect : sig
      type diagnostic
      type observation =
        | Diagnostic of diagnostic
        | Resize of Types.Size.t
      type item = Observation of observation | Update of Update.t
      module Item_sequence : sig
        type t
        val append : t -> t -> t
        val empty : t
        val fold_left : ('a -> item -> 'a) -> 'a -> t -> 'a
        val pp : Format.formatter -> t -> unit
      end
      module Observation_sequence : sig
        type t
        val append : t -> t -> t
        val empty : t
        val pp : Format.formatter -> t -> unit
      end
      val pp_diagnostic : Format.formatter -> diagnostic -> unit
      val pp_item : Format.formatter -> item -> unit
      val pp_observation : Format.formatter -> observation -> unit
    end

`Cell_blocks`, `Damage`, and `Snapshot_cells` disclose no mutable array.
`Update.Batch` and `Effect.Item_sequence` expose ordered folds rather than a
set/map traversal because their order is semantic.

### Decoder and renderer

    module Decoder : sig
      type continuation
      type error =
        [ `Internal_invariant of string
        | `Invalid_slice
        | `Unicode of Unicode.error ]
      type decoded = { continuation : continuation; items : Effect.Item_sequence.t }
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      val feed : Policy.t -> continuation -> Types.slice
        -> (decoded, error) Err.t
      val finish : Policy.t -> continuation
        -> (decoded, error) Err.t
      val initial : continuation
      val pp : Format.formatter -> continuation -> unit
      val pp_decoded : Format.formatter -> decoded -> unit
    end

    module Patch : sig
      type error = [ `Generation_mismatch | `Lineage_mismatch ]
      type t
      val after_generation : t -> Generation.t
      val before_generation : t -> Generation.t
      val compose : t -> t -> (t, error) Err.t
      val lineage_id : t -> Lineage_id.t
      val normalize : t -> t
      val pp : Format.formatter -> t -> unit
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
    end

    module Renderer : sig
      type applied
      type damage
      type error =
        [ `Identifier_exhausted
        | `Invalid_operation
        | `Snapshot_limit_exceeded ]
      type snapshot
      type state
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      val apply : Policy.t -> state -> Update.Batch.t
        -> (applied, error) Err.t
      val initial : lineage_id:Lineage_id.t -> policy:Policy.t -> size:Types.Size.t -> state
      val damage : applied -> damage
      val patch : applied -> Patch.t
      val pp : Format.formatter -> state -> unit
      val pp_applied : Format.formatter -> applied -> unit
      val pp_damage : Format.formatter -> damage -> unit
      val pp_snapshot : Format.formatter -> snapshot -> unit
      val snapshot : applied -> snapshot
      val state : applied -> state
    end

`Decode_state`, `Grid`, and `State` are library-private. Tests receive their
structural statistics only through a test-only interface; applications hold
opaque decoder continuations, renderer states, snapshots, and patches.

### Terminfo, encoder, repaint, and facade

    module Description : sig
      type capability
      type error = [ `Capability_conflict | `Invalid_capability ]
      type t
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      module Capability_map : sig
        type t
        val find : t -> capability -> string option
        val merge : earlier:t -> later:t
          -> (t, error) Err.t
        val pp : Format.formatter -> t -> unit
      end
      val pp : Format.formatter -> t -> unit
      val pp_capability : Format.formatter -> capability -> unit
    end

    module Terminfo : sig
      type error =
        [ `Compiled_format of string
        | `Description of Description.error
        | `Source_syntax of string ]
      type resource = Compiled of bytes | Source of string
      val pp_error : Format.formatter -> error -> unit
      val pp_resource : Format.formatter -> resource -> unit
      module E : Err.S with type error = error
      val parse : Policy.t -> resource
        -> (Description.t, error) Err.t
      val resolve_use : Description.t -> lookup:(string -> Description.t option)
        -> (Description.t, error) Err.t
    end

    module Encoder : sig
      type byte_chunks
      type error = [ `Unexpressible_update of Update.t ]
      val pp_error : Format.formatter -> error -> unit
      module E : Err.S with type error = error
      val encode : Description.t -> Policy.t -> Update.Batch.t
        -> (byte_chunks, error) Err.t
      val fold_chunks : ('a -> Types.slice -> 'a) -> 'a -> byte_chunks -> 'a
      val pp_byte_chunks : Format.formatter -> byte_chunks -> unit
    end

    module Repaint : sig
      type error =
        [ `Generation_mismatch
        | `Incomplete_wide_pair
        | `Lineage_mismatch
        | `Unsupported_attachment
        | `Unsupported_observation
        | `Unsupported_presentation ]
      type target
      val pp_error : Format.formatter -> error -> unit
      val pp_target : Format.formatter -> target -> unit
      module E : Err.S with type error = error
      val compile : Description.t -> Policy.t -> target -> Patch.t
        -> (target * Update.Batch.t, error) Err.t
      val initial : lineage_id:Lineage_id.t -> policy:Policy.t -> size:Types.Size.t -> target
    end

    module Session : sig
      type error = [ `Decode of Decoder.error | `Render of Renderer.error ]
      type byte_input = Types.slice
      type out_of_band = Resize of Types.Size.t
      type input = Bytes of byte_input | Out_of_band of out_of_band
      type outcome
      type t
      val pp_error : Format.formatter -> error -> unit
      val pp_outcome : Format.formatter -> outcome -> unit
      val pp : Format.formatter -> t -> unit
      module E : Err.S with type error = error
      val finish : t -> (outcome, error) Err.t
      val ingest : t -> input
        -> (outcome, error) Err.t
      val initial : lineage_id:Lineage_id.t -> policy:Policy.t -> size:Types.Size.t -> t
      val items : outcome -> Effect.Item_sequence.t
      val patch : outcome -> Patch.t
      val snapshot : outcome -> Renderer.snapshot
      val successor : outcome -> t
    end

    module Tessera : sig
      type outcome = Session.outcome
      type session = Session.t
      type input = Session.input
      val finish : session -> (outcome, Session.error) Err.t
      val ingest : session -> input
        -> (outcome, Session.error) Err.t
      val initial : lineage_id:Lineage_id.t -> policy:Policy.t -> size:Types.Size.t -> session
      val outcome_items : outcome -> Effect.Item_sequence.t
      val outcome_patch : outcome -> Patch.t
      val outcome_snapshot : outcome -> Renderer.snapshot
      val pp_outcome : Format.formatter -> outcome -> unit
      val pp_session : Format.formatter -> session -> unit
      val session : outcome -> session
    end

`Encoder.encode` has no target state, and `Repaint.compile` has no I/O. An
adapter owns the ordered write of encoded byte chunks. `Tessera.ingest` is the
normal pure-core entry point; platform adapters serialise byte slices and
validated semantic out-of-band inputs, then process its returned outcome.

## Decoder mapping

| Input family | Action |
| --- | --- |
| Printable UTF-8 | Decode scalar, segment grapheme, emit Print when complete. Invalid input emits Invalid_utf8 and a replacement scalar. |
| C0: BEL, BS, HT, LF, VT, FF, CR | Emit diagnostic for BEL; map the others to Backspace, Horizontal_tab, Line_feed, or Carriage_return. |
| ESC 7, 8, D, M, E, H, c | Save_cursor, Restore_cursor, Scroll_up/Scroll_down behaviour operations, line feed with carriage return, Set_tab, and Reset. |
| CSI A/B/C/D/E/F/G/d/H/f | Emit cursor movement or position operation. Defaults are normalised from one-based terminal parameters to zero-based `Column.t`/`Row.t` values before update construction; E/F also reset the column. |
| CSI J/K/X/P/@/L/M/S/T | Emit erase, edit, or scroll operation. |
| CSI r, h, l, ?h, ?l | Emit margins or selected mode delta: origin, auto-wrap, cursor visibility, and alternate screen. DEC 1049 is distinct from 47/1047 and saves/restores the primary cursor. |
| CSI m | Parse style groups including reset, rendition flags, indexed colours, and RGB colours; emit Set_style. |
| OSC 0/2 | Emit Set_title after bounded payload collection. |
| OSC/DCS/APC/PM other payloads | Recognise terminator, emit one bounded Unsupported_sequence observation, and return to Ground. |

CSI parameters are accumulated as decimal integers with a checked maximum count and digit budget. A malformed or oversized sequence enters the appropriate bounded discard state and never mutates logical state.

Framing and semantic dispatch are separate. The table-driven framer recognises
C0/C1 controls, ESC, CSI, DCS, OSC, APC, PM/SOS, cancellation, and string
termination across arbitrary byte boundaries; policy then decides whether a
framed sequence has a supported meaning. Once a limit is reached or an
unsupported string construct is identified, the decoder retains only its
bounded diagnostic prefix and remains in `Discard_string` until the matching
terminator. It never reinterprets discarded string payload as printable text,
and the pure core exposes no user-installed or asynchronous parser callbacks.

## Module connections

    Observation / terminal-emulator path (used by Tessera and tessera-proxy)

    application / PTY output bytes ──► Bytes ────────────────┐
                                                            ▼
    validated TTY / browser resize ──► Out_of_band Resize ─► Tessera.Session
                                                            │
                                 Bytes only ────────────────┼─► Tessera.Decoder
                                                            │        │
                                                            │        ├─ Decode_state
                                                            │        └─ Unicode
                                                            ▼
                                                     Tessera.Renderer
                                                            │
                                                            ├─ State / Grid
                                                            ├─ Cell / Style / Mode
                                                            ├─ snapshot + Patch.t ──► observer / Application UI
                                                            └─ renderer checkpoint

    Decoder continuation + renderer checkpoint ──► optional Session checkpoint

    Controlled output / application-rendering path (not used by transparent proxy)

    Application UI / application model
        │  desired absolute display change
        ▼
    Patch.t ──► Tessera.Repaint.compile ──► Update.Batch.t ──► Tessera.Encoder.encode
                    │                              │                     │
                    ├─ Repaint.target              │                     ▼
                    │  (lineage + generation +     │              control-character
                    │   known target projection)   │                 byte chunks
                    └──────────────────────────────┘                     │
                                                                          ▼
                                                               owned terminal output stream

    Description + Policy ─► Repaint and Encoder
    Policy ───────────────► Decoder and Renderer
    Local Error/E ────────► constructors at every public boundary
    Pp/expect/QCheck ─────► public Tessera facade only

The two paths meet only at shared immutable values (`Patch.t` and
`Update.Batch.t`); there is no Decoder → Encoder shortcut. Decoding then
encoding never promises preservation of original bytes. Conversely, the
controlled `Patch → Repaint → Encoder → Decoder → Renderer` route is required
to preserve `Patch.normalize` and its successor projection for the explicitly
repaintable subset, with a shared canonical pre-patch state. The transparent
proxy follows only the observation path and forwards the original byte stream
unchanged. Snapshots and renderer checkpoints belong to Renderer; an optional
Session checkpoint merely combines those renderer-owned values with the decoder
continuation. Tests use Session for end-to-end observation expectations and
Decoder/Renderer directly for component expectations; Repaint/Encoder tests
use a controlled target and never a proxy relay.

## Implementation order and acceptance gates

| Stage | Modules completed | Acceptance gate |
| --- | --- | --- |
| 1. Skeleton and value model | Types, Limits, Policy, local error domains, Style, Mode, Cell, Update, Effect, Tessera facade stubs | Native, JSOO, and Melange compile. Expect tests cover checked UInt/ID/geometry constructors, policy validation, SGR printing, mode deltas, and stable printers; compile-fail fixtures prove unlike wrappers do not unify. |
| 2. Unicode and grid | Unicode, Grid, State | Expect tests cover fragmented UTF-8, combining/wide cells, and page-copy behaviour. QCheck validates wide-cell pairing and coordinate bounds. |
| 3. Renderer and patch algebra | Patch, Renderer, and Pp renderer output | Expect tests cover cursor rules, autowrap, margins, editing, scrolling, SGR, primary/alternate switching, title, no-reflow resize, same-geometry full refresh, patch compaction, and patch composition. Allocation test proves a one-cell edit copies at most one grid page. |
| 4. Decoder | Decode_state and Decoder | Expect tests cover every mapping table row. QCheck splits every fixture at random byte boundaries and requires identical items/continuation outcome. Native fuzzing proves malformed bytes remain bounded and do not raise. |
| 5. Session and hardening | Session, session expect tests, Properties, Allocation | Composition tests compare byte `Session.ingest` with Decoder.feed followed by Renderer.apply, and compare sequential patches with Patch.compose. Expect/property tests cover resize/byte interleavings, same-geometry resize records and full refresh, decoder finish, and checkpoint boundaries between ingresses. Native allocation budgets cover printable runs, scrolling, alternate-screen switch, resize refresh, and snapshot creation. Cross-backend expect output is identical. |
| 6. Controlled output (second increment) | Description, Encoder, Target, and Repaint | Expect tests cover `Patch → Repaint.compile → Update.Batch → Encoder.encode`; the repaintable subset also completes `Patch → Repaint → Encoder → Decoder → Renderer` with equal normalised patch and successor projection. Mismatched lineage/generation and unsupported cells/effects fail before writing bytes; a full repaint recovers a reset controlled target. |

## Test commands and artefacts

## Working practices

The following conventions are part of this implementation, not incidental
review preferences:

- Make commits at completed semantic milestones.  A commit includes its
  expect coverage and the applicable portable-backend verification; it is not
  merely an intermediate formatting checkpoint.
- Write behavioural tests as `ppx_expect` fixtures.  Use public module
  printers for domain values.  Test setup may use structural `Fmt` combinators
  (not bespoke semantic printers), and result output uses `Fmt.result` rather
  than unwrapping or asserting successful results.
- Printers belong to the modules that own the public type.  Use `Fmt` for
  module printers as well as expect fixtures when it improves the formatting,
  provided its runtime dependency is declared and works on native, JSOO, and
  Melange.  `Format` remains suitable for simple printers; never add a printer
  dependency that prevents the Melange build.
- Prefer pure recursive traversal and labelled recursive parameters over
  mutable parser state or short-lived transition records.  A record remains
  appropriate for durable state with cohesive invariants, such as decoder
  continuations and renderer state.
- Preserve the native, JSOO, and Melange targets throughout the work.  Run the
  complete verification command, `make precommit`, before each milestone
  commit.  It runs formatting, build, expect tests, both JavaScript targets,
  format checking, and `git diff --check`.

The test Dune file defines:

- tessera_expect: ppx_expect tests under the runtest alias;
- tessera_properties: deterministic QCheck seed recorded on failure;
- tessera_allocation: native release executable using Gc.allocated_bytes;
- tessera_memtrace: native release benchmark executable producing a memtrace trace when MEMTRACE is set.

Every expect fixture prints cells as content, width, style, and line id; prints damage rectangles in normalised order; and prints diagnostics without err_trace stacks. Allocation thresholds are committed as named constants next to their workload, after warm-up and a major collection. Grid statistics expose copied_pages and live_pages only to Allocation tests.

## Design-validation matrix

The following tests validate the architectural claims made by this increment. They are required in addition to individual feature fixtures.

| Design claim | Test | Required assertion |
| --- | --- | --- |
| Parser and renderer are independent | Decoder fixtures never construct Renderer.state; renderer fixtures supply Update.batch values without calling Decoder. Dune dependency inspection keeps Decoder free of State/Grid/Renderer imports and Renderer free of Decoder/Decode_state imports. | Both component suites pass independently and the library dependency graph matches the module-connections diagram. |
| Session composition is faithful | For every decoder fixture and random chunking, compare `Session.ingest (Bytes slice)` with Decoder.feed followed by Renderer.apply performed by the test. | Final renderer state, ordered diagnostics, damage, and snapshot are equal. |
| Resize ingress is explicit and ordered | Interleave byte ingresses with distinct, same-geometry, and coalesced resize ingresses; checkpoint only after each completed step. | Each accepted resize advances generation, emits one ordered `Resize` observation, and yields a full-damage full projection even when its size is unchanged. Replay and restore produce the same sequence and final state. |
| Controlled output round trip is faithful | Start a renderer reference state and `Repaint.target` at the same canonical projection; compile only a generated repaintable patch, encode it, decode the bytes, then apply them to the reference renderer. | `Patch.normalize` and successor screen projection equal those of the source patch; source and emitted byte strings are never compared. |
| Chunking does not change meaning | Feed each byte fixture whole, one byte at a time, and at hundreds of generated split points. | Equal updates, diagnostics, continuation-at-end, renderer state, damage, and snapshot. |
| State is immutable | Retain every intermediate State/Session value during a scripted screen update; render snapshots from all retained values after later transitions. | Earlier snapshots and grid statistics are unchanged; only documented pages are newly allocated. |
| Type distinctions are enforced | Compile positive client examples using `UInt`, `Column`, `Row`, `Generation`, `Line_id`, and `Lineage_id`; compile-fail fixtures attempt to exchange unlike wrappers or use a negative raw count. | Positive examples compile; each deliberate category error is rejected, proving that type names are not cosmetic aliases. |
| Collection laws are explicit | Generate ordered batches/items, overlapping cell blocks, damage rectangles, tab-stop edits, and capability merges. | Batch/item append preserves order/duplicates; block overlay is last-writer-wins and canonical; damage union and tab add/remove are idempotent; capability lookup has one typed value per key. |
| State has local structural sharing | Apply a one-cell write, style change, edit, scroll, resize, and alternate-screen switch to a known grid. | copied_pages is bounded per operation; unchanged pages have physical identity in the test-only Grid debug API. |
| Rendering invariants always hold | Run the invariant checker after every random valid update batch and after every malformed decoder input. | Cursor and margins are in range; each Wide_continuation has a width-two lead immediately left; no lead lacks its continuation; every cell has a valid style and line id. |
| Invalid protocol data cannot alter state | Pair valid baseline input with malformed, unknown, oversized, and unterminated sequences at every parser state. | State is unchanged by the rejected sequence, exactly one bounded observation is emitted where specified, and the following valid sequence is processed normally. |
| Resource usage is bounded | Use maximum-sized CSI fields, unclosed OSC/DCS/APC/PM strings, invalid UTF-8 runs, and dimensions at/over policy limits. | Retained parser bytes, diagnostic count, snapshot cells, page count, and history-free state all remain within Policy.limits. |
| Unicode policy is deterministic | Fixtures cover combining marks, variation selectors, emoji/ZWJ sequences, ambiguous-width characters, width-two glyphs at final column, invalid UTF-8, and chunk boundaries inside each encoding. | The same grapheme/cell snapshot is produced on native, JSOO, and Melange from the recorded upstream Unicode submodule revisions. |
| Damage is precise and sufficient | Apply each operation to a state, then compare the new snapshot with the old snapshot cell by cell. | Every changed visible cell lies in damage; operations expected to be local do not request full damage; resize/reset request full damage, including a same-geometry resize refresh. |
| Diagnostics are deterministic and safe | Print each policy, decode, and render error through its stable payload printer under Err.Config.deterministic. | Expect output contains position/kind/payload only, has no stack/address/runtime-specific text, and is identical across portable targets. |
| Pure-core portability is real | Build and run the same model, decoder, renderer, and session expect fixtures in native, JSOO, and Melange CI jobs. | No target-specific conditional code occurs under src/ and all fixture outputs are byte-for-byte equal. |
| Allocation budget detects regressions | Run the fixed native release workloads after warm-up and major collection; capture a memtrace profile for the benchmark workload. | Per-update allocations remain below committed budgets, and the profile has no full-grid copy on local edits. |
| Public API is intentional | Compile a small external-client test that imports only Tessera, not implementation modules. | The client can construct policy/session, serialise byte and resize ingress, finish a stream, inspect snapshot/damage/diagnostics, and cannot access Grid, Decode_state, or mutable internals. |

Completion means all five stages pass on the three portable targets, decoder chunking is deterministic, renderer state remains immutable across older session values, and the allocation/structural-sharing budgets hold.
