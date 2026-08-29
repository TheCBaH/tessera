(** Constrained HTML fragment projected from a {!Web_frame.t}.

    No theme parameter: this is a pure, theme-independent function of {!Web_frame.t} alone, so frame bytes never change
    when a browser's theme changes. [Default]/[Indexed] colours become CSS custom-property references
    ([var(--tessera-default-fg)], [var(--tessera-color-<n>)]) that a separately-versioned stylesheet resolves at paint
    time; [Rgb] becomes a precomputed [#rrggbb] string. Rendition
    (bold/faint/invisible/inverse/italic/strikethrough/underline) maps to a fixed, closed set of CSS classes; the
    stylesheet, not this module, defines what those classes do visually (e.g. [.tessera-inverse] swaps which custom
    property is used for the foreground versus background colour).

    Accessible text is carried per row ([row.text]), not as one frame-wide string: a [Delta] {!Web_frame.t} carries only
    its damaged rows, so a single concatenated mirror would either drop every unchanged row (if replaced wholesale each
    time) or miss edits (if left alone). Keying it by row lets a browser driver replace exactly the same DOM node it
    replaces for the row's visual fragment -- an untouched row's accessible text is simply never revisited, so it stays
    correct without this module needing to see it again.

    Every positioned element carries an explicit CSS [grid-column] (and, for the row container and cursor, [grid-row])
    placement -- not just [data-start]/[data-width] -- so a browser that merely mounts the emitted markup places every
    glyph and span at its specified terminal column via CSS alone, with no JavaScript layout computation. [t.columns]/
    [t.row_count] are emitted as [--tessera-columns]/[--tessera-rows] custom properties on the frame root, so the
    separately-versioned stylesheet can size its grid ([grid-template-columns: repeat(var(--tessera-columns), ...)])
    without this module hard-coding any layout rule itself -- placement values are this module's job, the grid
    definition is the stylesheet's.

    [color_value]/[style] are public, transparent records -- {!Web_json} needs to construct and pattern-match them
    directly -- so a caller can hand-build one carrying a [Var]/[Hex] string or class name outside the closed set
    {!of_frame} ever produces (e.g. [Hex "red;position:fixed;inset:0"], smuggling extra CSS declarations into the
    emitted [style] attribute: HTML attribute escaping neutralizes a literal quote character, not CSS's own [;]/[:]
    separators). Decoding validates this closed set at the JSON boundary, but that does not protect a direct caller of
    this module, or an encoder given a hand-built value. {!to_html} therefore validates every [color_value]/class
    against the same closed set itself and refuses to render anything outside it, so the rendering contract holds
    regardless of how its input was constructed. *)

type color_value = Var of string | Hex of string
type style = { fg : color_value; bg : color_value; classes : string list }
type background_span = { start : int; width : int; style : style }
type glyph_span = { start : int; width : int; text : string; style : style }

type row = { index : int; background : background_span list; glyphs : glyph_span list; text : string }
(** [text] is this row's plain accessible text (one character per column, glyphs substituted in, blanks elsewhere). *)

type cursor = { column : int; row : int; visible : bool; pending_wrap : bool; style : style }
type t = { columns : int; row_count : int; rows : row list; cursor : cursor }

val of_frame : Web_frame.t -> t

val valid_color_value : color_value -> bool
(** [Var name] only for [--tessera-default-fg]/[--tessera-default-bg]/[--tessera-color-<n>] with [n] in [0, 255]
    (matching {!Tessera_model.Style.Palette_index}); [Hex v] only for exactly [#] followed by six lowercase hex digits.
    This is the exact closed set {!of_frame} ever produces, and the same test {!Web_json} applies at decode time -- both
    call this function rather than each keeping their own copy of the pattern. *)

val valid_class : string -> bool
(** Membership in the fixed, closed set of seven rendition classes {!of_frame} ever produces. *)

type error = [ `Invalid_color of color_value | `Invalid_class of string ]

module E : Err.S with type error = error

val validate : t -> (unit, error) Err.t
(** Every [fg]/[bg]/class on every background span, glyph, and the cursor is in the closed set {!valid_color_value}/
    {!valid_class} accept. *)

val to_html : t -> (string, error) Err.t
(** Canonical markup: escaped text, alphabetically-ordered classes, a fixed attribute order, and explicit grid placement
    on every positioned element (see above). Calls {!validate} first and never renders a value that fails it. *)

val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
