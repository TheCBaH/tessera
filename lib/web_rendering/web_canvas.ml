module Types = Tessera_foundation.Types
module UInt = Tessera_foundation.UInt
module Style = Tessera_model.Style
module Unicode = Tessera_model.Unicode

let int_of_column c = UInt.to_int (Types.Column.to_uint c)
let int_of_row r = UInt.to_int (Types.Row.to_uint r)

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

let pp_color ppf = function
  | Default -> Format.pp_print_string ppf "default"
  | Indexed i -> Format.fprintf ppf "indexed(%d)" i
  | Rgb (r, g, b) -> Format.fprintf ppf "rgb(%d,%d,%d)" r g b

let pp_op ppf = function
  | Fill v -> Format.fprintf ppf "fill(row=%d; start=%d; width=%d; color=%a)" v.row v.start v.width pp_color v.color
  | Glyph v ->
      Format.fprintf ppf "glyph(row=%d; column=%d; text=%S; color=%a; bold=%b; italic=%b; opacity=%g)" v.row v.column
        v.text pp_color v.paint.color v.paint.bold v.paint.italic v.paint.opacity
  | Underline v ->
      Format.fprintf ppf "underline(row=%d; start=%d; width=%d; color=%a)" v.row v.start v.width pp_color v.color
  | Strikethrough v ->
      Format.fprintf ppf "strikethrough(row=%d; start=%d; width=%d; color=%a)" v.row v.start v.width pp_color v.color
  | Cursor v ->
      Format.fprintf ppf "cursor(row=%d; column=%d; visible=%b; color=%a)" v.row v.column v.visible pp_color v.color

let pp ppf v =
  Format.fprintf ppf "canvas-frame(ops=[%a])"
    (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") pp_op)
    v.ops

let color_of = function
  | Style.Default -> Default
  | Style.Indexed i -> Indexed (Style.Palette_index.to_int i)
  | Style.Rgb rgb -> Rgb (Style.Rgb.red rgb, Style.Rgb.green rgb, Style.Rgb.blue rgb)

(* [inverse] swaps which colour paints the glyph versus the cell background. *)
let effective_fg_bg (s : Style.t) =
  if s.rendition.inverse then (s.background, s.foreground) else (s.foreground, s.background)

let background_ops row_i (span : Web_frame.background_span) =
  let start = int_of_column span.start and stop = int_of_column span.stop in
  let width = stop - start in
  let fg, bg = effective_fg_bg span.style in
  let fill = Fill { row = row_i; start; width; color = color_of bg } in
  let deco constructor flag = if flag then [ constructor { row = row_i; start; width; color = color_of fg } ] else [] in
  (fill :: deco (fun v -> Underline v) span.style.rendition.underline)
  @ deco (fun v -> Strikethrough v) span.style.rendition.strikethrough

let glyph_op row_i (g : Web_frame.glyph) =
  if g.style.rendition.invisible then None
  else
    let fg, _ = effective_fg_bg g.style in
    let opacity = if g.style.rendition.faint then 0.5 else 1.0 in
    Some
      (Glyph
         {
           row = row_i;
           column = int_of_column g.start;
           text = g.text;
           paint = { color = color_of fg; bold = g.style.rendition.bold; italic = g.style.rendition.italic; opacity };
         })

let row_ops (row : Web_frame.row) =
  let row_i = int_of_row row.index in
  List.concat_map (background_ops row_i) row.background @ List.filter_map (glyph_op row_i) row.glyphs

let cursor_op (p : Web_frame.presentation) =
  let fg, _ = effective_fg_bg p.cursor_style in
  Cursor
    {
      row = int_of_row p.cursor_position.row;
      column = int_of_column p.cursor_position.column;
      visible = p.cursor_visible;
      color = color_of fg;
    }

let of_frame (frame : Web_frame.t) = { ops = List.concat_map row_ops frame.rows @ [ cursor_op frame.presentation ] }
