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
type row = { index : int; background : background_span list; glyphs : glyph_span list; text : string }
type cursor = { column : int; row : int; visible : bool; pending_wrap : bool; style : style }
type t = { columns : int; row_count : int; rows : row list; cursor : cursor }

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

(* [text] is per row, not one frame-wide blob: a [Delta] frame carries only its damaged rows (see
   {!Web_frame.of_outcome}), so a single concatenated string would either drop every unchanged row's text (if
   replaced wholesale) or miss edits (if left alone). Keying the accessible mirror by row lets a browser driver
   replace exactly the same DOM node it replaces for the visual row -- unchanged rows are never touched, so their
   accessible text stays correct without this module ever seeing them. *)
let row_of ~columns (row : Web_frame.row) =
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
  { index; background; glyphs; text = row_text ~columns row }

(* The closed token/class set {!of_frame} above ever produces. {!Web_json} validates decoded wire values against
   this same set (calling these functions rather than keeping its own copy of the pattern), but that protects only
   the JSON boundary -- [color_value]/[style] are public, transparent records, so a caller can hand-build one
   outside this set and pass it straight to {!to_html}. [to_html] therefore checks this set itself before
   rendering (see {!validate}), so the rendering contract holds regardless of how its input was constructed. *)

let is_digit c = c >= '0' && c <= '9'
let is_lower_hex_digit c = is_digit c || (c >= 'a' && c <= 'f')

let valid_color_value = function
  | Var name -> (
      name = "--tessera-default-fg" || name = "--tessera-default-bg"
      ||
      let prefix = "--tessera-color-" in
      let plen = String.length prefix in
      String.length name > plen
      && String.equal (String.sub name 0 plen) prefix
      &&
      let digits = String.sub name plen (String.length name - plen) in
      String.length digits > 0
      && String.for_all is_digit digits
      && match int_of_string_opt digits with Some n -> Style.Palette_index.of_int n <> None | None -> false)
  | Hex v ->
      (* Already fully bounds each channel to 0..255: exactly two lowercase hex digits per channel. *)
      String.length v = 7 && v.[0] = '#' && String.for_all is_lower_hex_digit (String.sub v 1 6)

let valid_class c =
  List.mem c
    [
      "tessera-bold";
      "tessera-faint";
      "tessera-invisible";
      "tessera-inverse";
      "tessera-italic";
      "tessera-strikethrough";
      "tessera-underline";
    ]

let of_frame (frame : Web_frame.t) =
  let columns = UInt.to_int (Types.Size.columns frame.presentation.size) in
  let row_count = UInt.to_int (Types.Size.rows frame.presentation.size) in
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
  { columns; row_count; rows = List.map (row_of ~columns) frame.rows; cursor }

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

(* HTML-attribute-escaped (via [escape], not OCaml's [%S]): [%S] escapes ["] as the two characters [\"], which an
   HTML attribute parser does not understand as an escape -- the literal ["] byte still closes the quoted attribute
   value, letting attacker-controlled content break out and inject further attributes. *)
let css_value = function Var name -> Printf.sprintf "var(%s)" name | Hex h -> h
let style_attr (s : style) = Printf.sprintf "--tessera-fg:%s;--tessera-bg:%s" (css_value s.fg) (css_value s.bg)
let class_attr base (s : style) = String.concat " " (base :: s.classes)

(* Explicit CSS grid placement, not just [data-start]/[data-width]: glyphs need explicit grid column and
   span-width properties so normal browser line wrapping, whitespace collapse, and proportional layout cannot
   alter terminal columns. A span's [grid-column] is placement data (which cells
   this element occupies), computed here; the grid itself ([display:grid], [grid-template-columns], sizing,
   subgrid) is the static stylesheet's job, not this module's -- it only needs to know the column/row counts,
   carried as the [--tessera-columns]/[--tessera-rows] custom properties on the frame root. CSS grid lines are
   1-indexed, so a zero-based [start] becomes line [start + 1]. *)
let grid_column ~start ~width = Printf.sprintf "grid-column:%d / span %d" (start + 1) width

let add_background buf (s : background_span) =
  Buffer.add_string buf
    (Printf.sprintf "<span class=\"%s\" style=\"%s;%s\" data-start=\"%d\" data-width=\"%d\"></span>"
       (escape (class_attr "tessera-bg" s.style))
       (escape (style_attr s.style))
       (escape (grid_column ~start:s.start ~width:s.width))
       s.start s.width)

let add_glyph buf (g : glyph_span) =
  Buffer.add_string buf
    (Printf.sprintf "<span class=\"%s\" style=\"%s;%s\" data-start=\"%d\" data-width=\"%d\">%s</span>"
       (escape (class_attr "tessera-glyph" g.style))
       (escape (style_attr g.style))
       (escape (grid_column ~start:g.start ~width:g.width))
       g.start g.width (escape g.text))

let add_row buf (r : row) =
  Buffer.add_string buf
    (Printf.sprintf "<div class=\"tessera-row\" style=\"grid-row:%d\" data-row=\"%d\">" (r.index + 1) r.index);
  List.iter (add_background buf) r.background;
  List.iter (add_glyph buf) r.glyphs;
  Buffer.add_string buf (Printf.sprintf "<span class=\"tessera-sr-only\">%s</span>" (escape r.text));
  Buffer.add_string buf "</div>"

let add_cursor buf (c : cursor) =
  Buffer.add_string buf
    (Printf.sprintf
       "<div class=\"%s\" style=\"%s;grid-column:%d;grid-row:%d\" data-column=\"%d\" data-row=\"%d\" \
        data-visible=\"%b\" data-pending-wrap=\"%b\"></div>"
       (escape (class_attr "tessera-cursor" c.style))
       (escape (style_attr c.style))
       (c.column + 1) (c.row + 1) c.column c.row c.visible c.pending_wrap)

type error = [ `Invalid_color of color_value | `Invalid_class of string ]

let pp_error ppf = function
  | `Invalid_color (Var name) -> Format.fprintf ppf "invalid-color(var(%s))" name
  | `Invalid_color (Hex h) -> Format.fprintf ppf "invalid-color(%s)" h
  | `Invalid_class c -> Format.fprintf ppf "invalid-class(%S)" c

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

exception Invalid of error

let check_style (s : style) =
  if not (valid_color_value s.fg) then raise (Invalid (`Invalid_color s.fg));
  if not (valid_color_value s.bg) then raise (Invalid (`Invalid_color s.bg));
  List.iter (fun c -> if not (valid_class c) then raise (Invalid (`Invalid_class c))) s.classes

let validate (t : t) =
  try
    List.iter
      (fun (r : row) ->
        List.iter (fun (s : background_span) -> check_style s.style) r.background;
        List.iter (fun (g : glyph_span) -> check_style g.style) r.glyphs)
      t.rows;
    check_style t.cursor.style;
    Ok ()
  with Invalid e -> E.fail e

let to_html (t : t) =
  let open Err.Syntax in
  let+ () = validate t in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf
    (Printf.sprintf "<div class=\"tessera-frame\" style=\"--tessera-columns:%d;--tessera-rows:%d\">" t.columns
       t.row_count);
  List.iter (add_row buf) t.rows;
  add_cursor buf t.cursor;
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
  Format.fprintf ppf "row(index=%d; background=[%a]; glyphs=[%a]; text=%S)" r.index (pp_list pp_background) r.background
    (pp_list pp_glyph) r.glyphs r.text

let pp_cursor ppf (c : cursor) =
  Format.fprintf ppf "cursor(column=%d; row=%d; visible=%b; pending-wrap=%b; style=%a)" c.column c.row c.visible
    c.pending_wrap pp_style c.style

let pp ppf (t : t) =
  let pp_list pp = Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") pp in
  Format.fprintf ppf "html-frame(columns=%d; row-count=%d; rows=[%a]; cursor=%a)" t.columns t.row_count (pp_list pp_row)
    t.rows pp_cursor t.cursor
