module Types = Tessera_foundation.Types
module UInt = Tessera_foundation.UInt
module Style = Tessera_model.Style
module Unicode = Tessera_model.Unicode

let int_of_column c = UInt.to_int (Types.Column.to_uint c)
let int_of_row r = UInt.to_int (Types.Row.to_uint r)
let glyph_width_columns = function Unicode.One | Unicode.Zero -> 1 | Unicode.Two -> 2

type color_value = Var of string | Hex of string
type style = { fg : color_value; bg : color_value; classes : string list }
type background_span = { start : int; width : int; style : style }
type glyph_span = { start : int; width : int; text : string; style : style }
type row = { index : int; background : background_span list; glyphs : glyph_span list }
type cursor = { column : int; row : int; visible : bool; pending_wrap : bool; style : style }
type t = { rows : row list; cursor : cursor; accessible_text : string }

let classes_of (r : Style.rendition) =
  List.filter_map
    (fun (flag, name) -> if flag then Some name else None)
    [
      (r.bold, "tessera-bold");
      (r.faint, "tessera-faint");
      (r.invisible, "tessera-invisible");
      (r.inverse, "tessera-inverse");
      (r.italic, "tessera-italic");
      (r.strikethrough, "tessera-strikethrough");
      (r.underline, "tessera-underline");
    ]

let color_value_of ~fg = function
  | Style.Default -> Var (if fg then "--tessera-default-fg" else "--tessera-default-bg")
  | Style.Indexed i -> Var (Printf.sprintf "--tessera-color-%d" (Style.Palette_index.to_int i))
  | Style.Rgb rgb -> Hex (Printf.sprintf "#%02x%02x%02x" (Style.Rgb.red rgb) (Style.Rgb.green rgb) (Style.Rgb.blue rgb))

let style_of (s : Style.t) =
  {
    fg = color_value_of ~fg:true s.foreground;
    bg = color_value_of ~fg:false s.background;
    classes = classes_of s.rendition;
  }

let row_of (row : Web_frame.row) =
  let index = int_of_row row.index in
  let background =
    List.map
      (fun (s : Web_frame.background_span) ->
        let start = int_of_column s.start and stop = int_of_column s.stop in
        { start; width = stop - start; style = style_of s.style })
      row.background
  in
  let glyphs =
    List.map
      (fun (g : Web_frame.glyph) ->
        { start = int_of_column g.start; width = glyph_width_columns g.width; text = g.text; style = style_of g.style })
      row.glyphs
  in
  { index; background; glyphs }

let row_text ~columns (row : Web_frame.row) =
  let buf = Buffer.create columns in
  let rec go col glyphs =
    if col >= columns then ()
    else
      match glyphs with
      | (g : Web_frame.glyph) :: rest when int_of_column g.start = col ->
          Buffer.add_string buf g.text;
          go (col + glyph_width_columns g.width) rest
      | glyphs ->
          Buffer.add_char buf ' ';
          go (col + 1) glyphs
  in
  go 0 row.glyphs;
  Buffer.contents buf

let of_frame (frame : Web_frame.t) =
  let columns = UInt.to_int (Types.Size.columns frame.presentation.size) in
  let accessible_text = String.concat "\n" (List.map (row_text ~columns) frame.rows) in
  let p = frame.presentation in
  let cursor =
    {
      column = int_of_column p.cursor_position.column;
      row = int_of_row p.cursor_position.row;
      visible = p.cursor_visible;
      pending_wrap = p.cursor_pending_wrap;
      style = style_of p.cursor_style;
    }
  in
  { rows = List.map row_of frame.rows; cursor; accessible_text }

(* --- canonical HTML serialization --- *)

let escape s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let css_value = function Var name -> Printf.sprintf "var(%s)" name | Hex h -> h
let style_attr (s : style) = Printf.sprintf "--tessera-fg:%s;--tessera-bg:%s" (css_value s.fg) (css_value s.bg)
let class_attr base (s : style) = String.concat " " (base :: s.classes)

let add_background buf (s : background_span) =
  Buffer.add_string buf
    (Printf.sprintf "<span class=%S style=%S data-start=\"%d\" data-width=\"%d\"></span>"
       (class_attr "tessera-bg" s.style) (style_attr s.style) s.start s.width)

let add_glyph buf (g : glyph_span) =
  Buffer.add_string buf
    (Printf.sprintf "<span class=%S style=%S data-start=\"%d\" data-width=\"%d\">%s</span>"
       (class_attr "tessera-glyph" g.style) (style_attr g.style) g.start g.width (escape g.text))

let add_row buf (r : row) =
  Buffer.add_string buf (Printf.sprintf "<div class=\"tessera-row\" data-row=\"%d\">" r.index);
  List.iter (add_background buf) r.background;
  List.iter (add_glyph buf) r.glyphs;
  Buffer.add_string buf "</div>"

let add_cursor buf (c : cursor) =
  Buffer.add_string buf
    (Printf.sprintf
       "<div class=%S style=%S data-column=\"%d\" data-row=\"%d\" data-visible=\"%b\" data-pending-wrap=\"%b\"></div>"
       (class_attr "tessera-cursor" c.style) (style_attr c.style) c.column c.row c.visible c.pending_wrap)

let to_html (t : t) =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "<div class=\"tessera-frame\">";
  List.iter (add_row buf) t.rows;
  add_cursor buf t.cursor;
  Buffer.add_string buf (Printf.sprintf "<div class=\"tessera-sr-only\">%s</div>" (escape t.accessible_text));
  Buffer.add_string buf "</div>";
  Buffer.contents buf

let pp_color_value ppf = function
  | Var name -> Format.fprintf ppf "var(%s)" name
  | Hex h -> Format.pp_print_string ppf h

let pp_style ppf (s : style) =
  Format.fprintf ppf "style(fg=%a; bg=%a; classes=[%s])" pp_color_value s.fg pp_color_value s.bg
    (String.concat "; " s.classes)

let pp_background ppf (s : background_span) =
  Format.fprintf ppf "background(start=%d; width=%d; style=%a)" s.start s.width pp_style s.style

let pp_glyph ppf (g : glyph_span) =
  Format.fprintf ppf "glyph(start=%d; width=%d; text=%S; style=%a)" g.start g.width g.text pp_style g.style

let pp_row ppf (r : row) =
  let pp_list pp = Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") pp in
  Format.fprintf ppf "row(index=%d; background=[%a]; glyphs=[%a])" r.index (pp_list pp_background) r.background
    (pp_list pp_glyph) r.glyphs

let pp_cursor ppf (c : cursor) =
  Format.fprintf ppf "cursor(column=%d; row=%d; visible=%b; pending-wrap=%b; style=%a)" c.column c.row c.visible
    c.pending_wrap pp_style c.style

let pp ppf (t : t) =
  let pp_list pp = Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") pp in
  Format.fprintf ppf "html-frame(rows=[%a]; cursor=%a; accessible-text=%S)" (pp_list pp_row) t.rows pp_cursor t.cursor
    t.accessible_text
