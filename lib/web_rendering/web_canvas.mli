(** Canvas 2D paint operations projected from a {!Web_frame.t}.

    Unlike {!Web_html}, rendition is resolved here into concrete paint attributes (this is the last representation
    before a Canvas API call): [inverse] swaps which colour paints the glyph versus the cell background, [invisible]
    suppresses the glyph draw (the background fill still happens), [bold]/[italic] become font hints, [faint] becomes an
    opacity hint. Colour stays symbolic for [Default]/[Indexed] (a future JS palette table resolves them) and concrete
    for [Rgb]. *)

type color = Default | Indexed of int | Rgb of int * int * int
type paint = { color : color; bold : bool; italic : bool; opacity : float }
type span_paint = { row : int; start : int; width : int; color : color }

type op =
  | Fill of span_paint
  | Glyph of { row : int; column : int; text : string; paint : paint }
  | Underline of span_paint
  | Strikethrough of span_paint
  | Cursor of { row : int; column : int; visible : bool; color : color }

type t = { ops : op list }

val of_frame : Web_frame.t -> t
val pp : Format.formatter -> t -> unit
val pp_color : Format.formatter -> color -> unit
val pp_op : Format.formatter -> op -> unit
