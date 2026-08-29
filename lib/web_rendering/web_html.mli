(** Constrained HTML fragment projected from a {!Web_frame.t}.

    No theme parameter: this is a pure, theme-independent function of {!Web_frame.t} alone, so frame bytes never change
    when a browser's theme changes. [Default]/[Indexed] colours become CSS custom-property references
    ([var(--tessera-default-fg)], [var(--tessera-color-<n>)]) that a separately-versioned stylesheet resolves at paint
    time; [Rgb] becomes a precomputed [#rrggbb] string. Rendition
    (bold/faint/invisible/inverse/italic/strikethrough/underline) maps to a fixed, closed set of CSS classes; the
    stylesheet, not this module, defines what those classes do visually (e.g. [.tessera-inverse] swaps which custom
    property is used for the foreground versus background colour). *)

type color_value = Var of string | Hex of string
type style = { fg : color_value; bg : color_value; classes : string list }
type background_span = { start : int; width : int; style : style }
type glyph_span = { start : int; width : int; text : string; style : style }
type row = { index : int; background : background_span list; glyphs : glyph_span list }
type cursor = { column : int; row : int; visible : bool; pending_wrap : bool; style : style }
type t = { rows : row list; cursor : cursor; accessible_text : string }

val of_frame : Web_frame.t -> t

val to_html : t -> string
(** Canonical markup: escaped text, alphabetically-ordered classes, a fixed attribute order. *)

val pp : Format.formatter -> t -> unit
