module Frame = Web_frame
module Html = Web_html
module Canvas = Web_canvas
module Types = Tessera_foundation.Types

let invalid what = Jsont.Error.msg Jsont.Meta.none ("invalid " ^ what)

(* A palette index is bounded 0..255, matching {!Tessera_model.Style.Palette_index}. Used for Canvas's raw numeric
   colours -- HTML's closed CSS token/class set is validated via {!Web_html.valid_color_value}/[valid_class]
   instead, the single source of truth for that contract ({!Web_html.to_html} enforces the same set on its own
   input, so both boundaries agree by construction rather than by keeping two copies of the pattern in sync). *)
let valid_channel n = n >= 0 && n <= 255

(* The canonical, non-negative decimal encoding [Tessera_foundation.UInt.pp] (and therefore
   [Generation.pp]/[Lineage_id.pp]) ever produces: only digits, no sign, no leading zero unless the
   whole string is exactly ["0"]. Applied to both [generation] and [lineage_id] on both the decode and
   encode paths (see [meta_jsont] and [validate_meta] below), so the "canonical decimal wire integer"
   contract documented in web_json.mli is enforced by this codec itself, not merely a convention a
   browser decoder happens to also check. *)
let canonical_decimal s =
  let n = String.length s in
  n > 0 && String.for_all (fun c -> c >= '0' && c <= '9') s && (s.[0] <> '0' || n = 1)

(* [start + width <= columns] without computing [start + width]: [Jsont.int] accepts any native int, including values
   near [max_int], so an externally-supplied [start + width] can wrap negative on the native runtime and slip past a
   naive addition-based check. Given [start >= 0] (checked separately wherever this is called), [start <= columns]
   guarantees [columns - start] cannot underflow, making the second comparison safe. *)
let fits_within ~start ~width ~columns = start <= columns && width <= columns - start

let kind_jsont =
  Jsont.map Jsont.string
    ~dec:(function "reset" -> Frame.Reset | "delta" -> Frame.Delta | _ -> invalid "frame kind")
    ~enc:(function Frame.Reset -> "reset" | Frame.Delta -> "delta")

let screen_jsont =
  Jsont.map Jsont.string
    ~dec:(function "primary" -> Types.Primary | "alternate" -> Types.Alternate | _ -> invalid "screen")
    ~enc:(function Types.Primary -> "primary" | Types.Alternate -> "alternate")

(* --- Web_html --- *)

let html_color_value_jsont =
  let obj =
    Jsont.Object.map (fun kind name value -> (kind, name, value))
    |> Jsont.Object.mem "kind" Jsont.string ~enc:(fun (k, _, _) -> k)
    |> Jsont.Object.opt_mem "name" Jsont.string ~enc:(fun (_, n, _) -> n)
    |> Jsont.Object.opt_mem "value" Jsont.string ~enc:(fun (_, _, v) -> v)
    |> Jsont.Object.finish
  in
  Jsont.map obj
    ~dec:(function
      | "var", Some n, None -> if Html.valid_color_value (Html.Var n) then Html.Var n else invalid "css variable name"
      | "hex", None, Some v -> if Html.valid_color_value (Html.Hex v) then Html.Hex v else invalid "hex colour"
      | _ -> invalid "html colour value")
    ~enc:(function Html.Var n -> ("var", Some n, None) | Html.Hex v -> ("hex", None, Some v))

let html_style_jsont =
  Jsont.Object.map (fun fg bg classes ->
      if List.for_all Html.valid_class classes then { Html.fg; bg; classes } else invalid "css class")
  |> Jsont.Object.mem "fg" html_color_value_jsont ~enc:(fun (s : Html.style) -> s.fg)
  |> Jsont.Object.mem "bg" html_color_value_jsont ~enc:(fun (s : Html.style) -> s.bg)
  |> Jsont.Object.mem "classes" (Jsont.list Jsont.string) ~enc:(fun (s : Html.style) -> s.classes)
  |> Jsont.Object.finish

let html_background_span_jsont =
  Jsont.Object.map (fun start width style ->
      if start >= 0 && width >= 1 then { Html.start; width; style } else invalid "background span")
  |> Jsont.Object.mem "start" Jsont.int ~enc:(fun (v : Html.background_span) -> v.start)
  |> Jsont.Object.mem "width" Jsont.int ~enc:(fun (v : Html.background_span) -> v.width)
  |> Jsont.Object.mem "style" html_style_jsont ~enc:(fun (v : Html.background_span) -> v.style)
  |> Jsont.Object.finish

let html_glyph_span_jsont =
  Jsont.Object.map (fun start width text style ->
      if start >= 0 && width >= 1 then { Html.start; width; text; style } else invalid "glyph span")
  |> Jsont.Object.mem "start" Jsont.int ~enc:(fun (v : Html.glyph_span) -> v.start)
  |> Jsont.Object.mem "width" Jsont.int ~enc:(fun (v : Html.glyph_span) -> v.width)
  |> Jsont.Object.mem "text" Jsont.string ~enc:(fun (v : Html.glyph_span) -> v.text)
  |> Jsont.Object.mem "style" html_style_jsont ~enc:(fun (v : Html.glyph_span) -> v.style)
  |> Jsont.Object.finish

let html_row_jsont =
  Jsont.Object.map (fun index background glyphs text ->
      if index >= 0 then { Html.index; background; glyphs; text } else invalid "row index")
  |> Jsont.Object.mem "index" Jsont.int ~enc:(fun (v : Html.row) -> v.index)
  |> Jsont.Object.mem "background" (Jsont.list html_background_span_jsont) ~enc:(fun (v : Html.row) -> v.background)
  |> Jsont.Object.mem "glyphs" (Jsont.list html_glyph_span_jsont) ~enc:(fun (v : Html.row) -> v.glyphs)
  |> Jsont.Object.mem "text" Jsont.string ~enc:(fun (v : Html.row) -> v.text)
  |> Jsont.Object.finish

let html_cursor_jsont =
  Jsont.Object.map (fun column row visible pending_wrap style ->
      if column >= 0 && row >= 0 then { Html.column; row; visible; pending_wrap; style } else invalid "cursor position")
  |> Jsont.Object.mem "column" Jsont.int ~enc:(fun (v : Html.cursor) -> v.column)
  |> Jsont.Object.mem "row" Jsont.int ~enc:(fun (v : Html.cursor) -> v.row)
  |> Jsont.Object.mem "visible" Jsont.bool ~enc:(fun (v : Html.cursor) -> v.visible)
  |> Jsont.Object.mem "pending_wrap" Jsont.bool ~enc:(fun (v : Html.cursor) -> v.pending_wrap)
  |> Jsont.Object.mem "style" html_style_jsont ~enc:(fun (v : Html.cursor) -> v.style)
  |> Jsont.Object.finish

(* Cross-field geometry: [columns]/[row_count] must be positive, every row's [index] must be unique and in range,
   every span must fit within [columns], background spans must exactly tile [0, columns) (no gaps, no overlaps --
   an empty or partial background list is rejected, not merely "in bounds"), glyphs must be pairwise
   non-overlapping, and the cursor must lie within the same bounds. Coordinate validity alone (the previous round's
   fix) is not sufficient: this enforces the same structural invariants {!Web_frame.validate} enforces on the
   pre-projection frame, since a decoded [Html.t] gets none of that checking for free. Values only checkable once
   every member is decoded, unlike the purely local checks in the [span]/[row]/[cursor] mappings above. *)
let html_frame_jsont =
  Jsont.Object.map (fun columns row_count rows cursor : Html.t ->
      let background_tiles (spans : Html.background_span list) =
        let rec go expect = function
          | [] -> expect = columns
          | (s : Html.background_span) :: rest ->
              fits_within ~start:s.start ~width:s.width ~columns && s.start = expect && go (s.start + s.width) rest
        in
        go 0 spans
      in
      let glyphs_ok (glyphs : Html.glyph_span list) =
        let rec go cursor = function
          | [] -> true
          | (g : Html.glyph_span) :: rest ->
              fits_within ~start:g.start ~width:g.width ~columns && g.start >= cursor && go (g.start + g.width) rest
        in
        go 0 glyphs
      in
      let row_ok (r : Html.row) = background_tiles r.background && glyphs_ok r.glyphs in
      (* Sorts the indices actually present (a list whose length is bounded by how many row objects the payload
         itself contains, never by the declared [row_count]) rather than allocating an [Array.make row_count]
         scratch table: [row_count] is an attacker-controlled [Jsont.int] with no upper bound, so sizing an
         allocation directly from it would let a tiny payload claiming an enormous [row_count] raise
         [Invalid_argument] or exhaust memory. *)
      let unique_and_in_range rows =
        let indices = List.sort compare (List.map (fun (r : Html.row) -> r.index) rows) in
        let rec no_duplicates = function [] | [ _ ] -> true | a :: (b :: _ as rest) -> a <> b && no_duplicates rest in
        List.for_all (fun i -> i < row_count) indices && no_duplicates indices
      in
      if
        columns >= 1 && row_count >= 1 && unique_and_in_range rows && List.for_all row_ok rows
        && cursor.Html.column < columns && cursor.Html.row < row_count
      then { columns; row_count; rows; cursor }
      else invalid "html frame geometry")
  |> Jsont.Object.mem "columns" Jsont.int ~enc:(fun (v : Html.t) -> v.columns)
  |> Jsont.Object.mem "row_count" Jsont.int ~enc:(fun (v : Html.t) -> v.row_count)
  |> Jsont.Object.mem "rows" (Jsont.list html_row_jsont) ~enc:(fun (v : Html.t) -> v.rows)
  |> Jsont.Object.mem "cursor" html_cursor_jsont ~enc:(fun (v : Html.t) -> v.cursor)
  |> Jsont.Object.finish

(* --- Web_canvas --- *)

let canvas_color_jsont =
  let obj =
    Jsont.Object.map (fun kind index r g b -> (kind, index, r, g, b))
    |> Jsont.Object.mem "kind" Jsont.string ~enc:(fun (k, _, _, _, _) -> k)
    |> Jsont.Object.opt_mem "index" Jsont.int ~enc:(fun (_, i, _, _, _) -> i)
    |> Jsont.Object.opt_mem "r" Jsont.int ~enc:(fun (_, _, r, _, _) -> r)
    |> Jsont.Object.opt_mem "g" Jsont.int ~enc:(fun (_, _, _, g, _) -> g)
    |> Jsont.Object.opt_mem "b" Jsont.int ~enc:(fun (_, _, _, _, b) -> b)
    |> Jsont.Object.finish
  in
  Jsont.map obj
    ~dec:(function
      | "default", None, None, None, None -> Canvas.Default
      | "indexed", Some i, None, None, None ->
          if valid_channel i then Canvas.Indexed i else invalid "canvas indexed colour"
      | "rgb", None, Some r, Some g, Some b ->
          if valid_channel r && valid_channel g && valid_channel b then Canvas.Rgb (r, g, b)
          else invalid "canvas rgb colour"
      | _ -> invalid "canvas colour")
    ~enc:(function
      | Canvas.Default -> ("default", None, None, None, None)
      | Canvas.Indexed i -> ("indexed", Some i, None, None, None)
      | Canvas.Rgb (r, g, b) -> ("rgb", None, Some r, Some g, Some b))

let canvas_paint_jsont =
  Jsont.Object.map (fun color bold italic opacity ->
      if opacity >= 0.0 && opacity <= 1.0 then { Canvas.color; bold; italic; opacity } else invalid "canvas opacity")
  |> Jsont.Object.mem "color" canvas_color_jsont ~enc:(fun (v : Canvas.paint) -> v.color)
  |> Jsont.Object.mem "bold" Jsont.bool ~enc:(fun (v : Canvas.paint) -> v.bold)
  |> Jsont.Object.mem "italic" Jsont.bool ~enc:(fun (v : Canvas.paint) -> v.italic)
  |> Jsont.Object.mem "opacity" Jsont.number ~enc:(fun (v : Canvas.paint) -> v.opacity)
  |> Jsont.Object.finish

let canvas_op_jsont =
  let obj =
    Jsont.Object.map (fun op row start width column text visible color paint ->
        (op, row, start, width, column, text, visible, color, paint))
    |> Jsont.Object.mem "op" Jsont.string ~enc:(fun (o, _, _, _, _, _, _, _, _) -> o)
    |> Jsont.Object.mem "row" Jsont.int ~enc:(fun (_, r, _, _, _, _, _, _, _) -> r)
    |> Jsont.Object.opt_mem "start" Jsont.int ~enc:(fun (_, _, s, _, _, _, _, _, _) -> s)
    |> Jsont.Object.opt_mem "width" Jsont.int ~enc:(fun (_, _, _, w, _, _, _, _, _) -> w)
    |> Jsont.Object.opt_mem "column" Jsont.int ~enc:(fun (_, _, _, _, c, _, _, _, _) -> c)
    |> Jsont.Object.opt_mem "text" Jsont.string ~enc:(fun (_, _, _, _, _, t, _, _, _) -> t)
    |> Jsont.Object.opt_mem "visible" Jsont.bool ~enc:(fun (_, _, _, _, _, _, v, _, _) -> v)
    |> Jsont.Object.opt_mem "color" canvas_color_jsont ~enc:(fun (_, _, _, _, _, _, _, c, _) -> c)
    |> Jsont.Object.opt_mem "paint" canvas_paint_jsont ~enc:(fun (_, _, _, _, _, _, _, _, p) -> p)
    |> Jsont.Object.finish
  in
  let valid_span_paint ~row ~start ~width = row >= 0 && start >= 0 && width >= 1 in
  Jsont.map obj
    ~dec:(fun (op, row, start, width, column, text, visible, color, paint) ->
      match (op, start, width, column, text, visible, color, paint) with
      | "fill", Some start, Some width, None, None, None, Some color, None ->
          if valid_span_paint ~row ~start ~width then Canvas.Fill { row; start; width; color }
          else invalid "canvas fill"
      | "underline", Some start, Some width, None, None, None, Some color, None ->
          if valid_span_paint ~row ~start ~width then Canvas.Underline { row; start; width; color }
          else invalid "canvas underline"
      | "strikethrough", Some start, Some width, None, None, None, Some color, None ->
          if valid_span_paint ~row ~start ~width then Canvas.Strikethrough { row; start; width; color }
          else invalid "canvas strikethrough"
      | "glyph", None, Some width, Some column, Some text, None, None, Some paint ->
          if row >= 0 && column >= 0 && width >= 1 then Canvas.Glyph { row; column; width; text; paint }
          else invalid "canvas glyph"
      | "cursor", None, None, Some column, None, Some visible, Some color, None ->
          if row >= 0 && column >= 0 then Canvas.Cursor { row; column; visible; color } else invalid "canvas cursor"
      | _ -> invalid "canvas op")
    ~enc:(function
      | Canvas.Fill v -> ("fill", v.row, Some v.start, Some v.width, None, None, None, Some v.color, None)
      | Canvas.Underline v -> ("underline", v.row, Some v.start, Some v.width, None, None, None, Some v.color, None)
      | Canvas.Strikethrough v ->
          ("strikethrough", v.row, Some v.start, Some v.width, None, None, None, Some v.color, None)
      | Canvas.Glyph v -> ("glyph", v.row, None, Some v.width, Some v.column, Some v.text, None, None, Some v.paint)
      | Canvas.Cursor v -> ("cursor", v.row, None, None, Some v.column, None, Some v.visible, Some v.color, None))

let canvas_frame_jsont =
  Jsont.Object.map (fun ops -> { Canvas.ops })
  |> Jsont.Object.mem "ops" (Jsont.list canvas_op_jsont) ~enc:(fun (v : Canvas.t) -> v.ops)
  |> Jsont.Object.finish

(* --- envelope --- *)

type geometry = { columns : int; rows : int }

type meta = {
  kind : Frame.kind;
  active : Types.screen;
  geometry : geometry;
  generation : string;
  lineage_id : string;
  title : string option;
}

type html_envelope = { schema : string; version : int; target : string; meta : meta; frame : Html.t }
type canvas_envelope = { schema : string; version : int; target : string; meta : meta; frame : Canvas.t }

let schema = "tessera.web-frame"
let version = 1
let html_target = "html"
let canvas_target = "canvas"

let geometry_jsont =
  Jsont.Object.map (fun columns rows -> if columns >= 1 && rows >= 1 then { columns; rows } else invalid "geometry")
  |> Jsont.Object.mem "columns" Jsont.int ~enc:(fun v -> v.columns)
  |> Jsont.Object.mem "rows" Jsont.int ~enc:(fun v -> v.rows)
  |> Jsont.Object.finish

let meta_jsont =
  Jsont.Object.map (fun kind active geometry generation lineage_id title ->
      if canonical_decimal generation && canonical_decimal lineage_id then
        { kind; active; geometry; generation; lineage_id; title }
      else invalid "generation/lineage_id must be a canonical non-negative decimal integer")
  |> Jsont.Object.mem "kind" kind_jsont ~enc:(fun v -> v.kind)
  |> Jsont.Object.mem "active" screen_jsont ~enc:(fun v -> v.active)
  |> Jsont.Object.mem "geometry" geometry_jsont ~enc:(fun v -> v.geometry)
  |> Jsont.Object.mem "generation" Jsont.string ~enc:(fun v -> v.generation)
  |> Jsont.Object.mem "lineage_id" Jsont.string ~enc:(fun v -> v.lineage_id)
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:(fun v -> v.title)
  |> Jsont.Object.finish

let valid_canvas_op ~columns ~rows = function
  | Canvas.Fill v | Canvas.Underline v | Canvas.Strikethrough v ->
      v.row < rows && fits_within ~start:v.start ~width:v.width ~columns
  | Canvas.Glyph v -> v.row < rows && fits_within ~start:v.column ~width:v.width ~columns
  | Canvas.Cursor v -> v.row < rows && v.column < columns

(* Extracts (row, start, width) triples, for [row_tiles]/[row_non_overlapping]/[distinct_rows] below. Every op has
   already passed {!valid_canvas_op}, so every [start]/[width] here is already known non-negative and in bounds --
   computing [start + width] in the walks below cannot overflow.

   Deliberately not grouped into an [Array.make rows_declared]-sized table: [rows] in the envelope's geometry is an
   attacker-controlled [Jsont.int] with no upper bound, so sizing an allocation directly from it would let a tiny
   payload claiming an enormous [rows] raise [Invalid_argument] or exhaust memory. Everything below instead scales
   with [List.length ops] -- bounded by how much JSON the payload itself actually contains. *)
let canvas_spans extract ops = List.filter_map extract ops
let distinct_rows spans = List.sort_uniq compare (List.map (fun (row, _, _) -> row) spans)
let spans_in_row spans row = List.filter_map (fun (r, s, w) -> if r = row then Some (s, w) else None) spans

(* An empty list is deliberately rejected here (never "trivially tiles"): callers only invoke this for a row that
   already has at least one background op, and completeness (every row of a [reset] having such an op at all) is
   checked separately. *)
let row_tiles ~columns spans =
  let sorted = List.sort (fun (a, _) (b, _) -> compare a b) spans in
  let rec go expect = function
    | [] -> expect = columns
    | (start, width) :: rest -> start = expect && go (start + width) rest
  in
  go 0 sorted

let row_non_overlapping spans =
  let sorted = List.sort (fun (a, _) (b, _) -> compare a b) spans in
  let rec go cursor = function [] -> true | (start, width) :: rest -> start >= cursor && go (start + width) rest in
  go 0 sorted

let html_envelope_jsont =
  Jsont.Object.map (fun schema_v version_v target_v meta frame : html_envelope ->
      if schema_v <> schema || version_v <> version || target_v <> html_target then
        invalid "html envelope schema/version/target"
      else if frame.Html.columns <> meta.geometry.columns || frame.Html.row_count <> meta.geometry.rows then
        invalid "html frame geometry disagrees with envelope metadata"
      else if meta.kind = Frame.Reset && List.length frame.Html.rows <> frame.Html.row_count then
        (* Every row's [index] is already unique and [< row_count] (html_frame_jsont), so having exactly
           [row_count] of them is sufficient to prove every row is present -- the protocol requires a [reset] to
           carry every row, not merely a structurally-valid subset. *)
        invalid "incomplete html reset"
      else { schema = schema_v; version = version_v; target = target_v; meta; frame })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun (v : html_envelope) -> v.schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun (v : html_envelope) -> v.version)
  |> Jsont.Object.mem "target" Jsont.string ~enc:(fun (v : html_envelope) -> v.target)
  |> Jsont.Object.mem "meta" meta_jsont ~enc:(fun (v : html_envelope) -> v.meta)
  |> Jsont.Object.mem "frame" html_frame_jsont ~enc:(fun (v : html_envelope) -> v.frame)
  |> Jsont.Object.finish

let canvas_envelope_jsont =
  Jsont.Object.map (fun schema_v version_v target_v meta frame : canvas_envelope ->
      let columns = meta.geometry.columns and rows = meta.geometry.rows in
      if schema_v <> schema || version_v <> version || target_v <> canvas_target then
        invalid "canvas envelope schema/version/target"
      else if not (List.for_all (valid_canvas_op ~columns ~rows) frame.Canvas.ops) then
        invalid "canvas op geometry disagrees with envelope metadata"
      else
        (* Coordinate validity alone is not sufficient (an earlier round's fix): a background must exactly tile
           the row it claims to describe (an empty or partial [ops: []] no longer decodes as if it were a
           legitimate blank row), glyphs on the same row must be pairwise non-overlapping, and a [reset] must
           supply background coverage for every row, mirroring the structural invariants
           {!Web_frame.validate}/{!Web_html}'s frame-level check enforce. *)
        let fills =
          canvas_spans (function Canvas.Fill v -> Some (v.row, v.start, v.width) | _ -> None) frame.Canvas.ops
        in
        let glyphs =
          canvas_spans (function Canvas.Glyph v -> Some (v.row, v.column, v.width) | _ -> None) frame.Canvas.ops
        in
        let fill_rows = distinct_rows fills in
        if not (List.for_all (fun row -> row_tiles ~columns (spans_in_row fills row)) fill_rows) then
          invalid "canvas background does not tile its row"
        else if not (List.for_all (fun row -> row_non_overlapping (spans_in_row glyphs row)) (distinct_rows glyphs))
        then invalid "canvas glyph overlap"
        else if meta.kind = Frame.Reset && List.length fill_rows <> rows then
          (* Every row in [fill_rows] is already distinct (from [distinct_rows]) and [< rows] (from
             [valid_canvas_op]), so having exactly [rows] of them is sufficient to prove every row has background
             coverage -- no need to walk [0, rows) explicitly. *)
          invalid "incomplete canvas reset"
        else { schema = schema_v; version = version_v; target = target_v; meta; frame })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun (v : canvas_envelope) -> v.schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun (v : canvas_envelope) -> v.version)
  |> Jsont.Object.mem "target" Jsont.string ~enc:(fun (v : canvas_envelope) -> v.target)
  |> Jsont.Object.mem "meta" meta_jsont ~enc:(fun (v : canvas_envelope) -> v.meta)
  |> Jsont.Object.mem "frame" canvas_frame_jsont ~enc:(fun (v : canvas_envelope) -> v.frame)
  |> Jsont.Object.finish

let meta_of_frame (frame : Frame.t) =
  let p = frame.presentation in
  {
    kind = frame.kind;
    active = p.active;
    geometry =
      {
        columns = Tessera_foundation.UInt.to_int (Types.Size.columns p.size);
        rows = Tessera_foundation.UInt.to_int (Types.Size.rows p.size);
      };
    generation = Format.asprintf "%a" Tessera_foundation.Generation.pp p.generation;
    lineage_id = Format.asprintf "%a" Tessera_foundation.Lineage_id.pp p.lineage_id;
    title = p.title;
  }

let html_envelope_of frame : html_envelope =
  { schema; version; target = html_target; meta = meta_of_frame frame; frame = Html.of_frame frame }

let canvas_envelope_of frame : canvas_envelope =
  { schema; version; target = canvas_target; meta = meta_of_frame frame; frame = Canvas.of_frame frame }

type error = [ `Json of string ]

let pp_error ppf (`Json msg) = Format.fprintf ppf "json(%s)" msg

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let of_result = function Ok v -> Ok v | Error msg -> E.fail (`Json msg)

(* [Jsont]'s [~enc] projections have no validation hook of their own (mirrors
   {!Web_html.to_html} calling {!Web_html.validate} before rendering): a hand-built envelope whose
   [meta.generation]/[meta.lineage_id] don't match {!canonical_decimal} would otherwise encode
   successfully, making the "canonical decimal wire integer" promise false for any caller other than
   {!meta_of_frame} (which always passes this by construction, since it builds both fields from
   [Generation.pp]/[Lineage_id.pp]). *)
let validate_meta (m : meta) : (unit, error) Err.t =
  if canonical_decimal m.generation && canonical_decimal m.lineage_id then Ok ()
  else E.fail (`Json "generation/lineage_id must be a canonical non-negative decimal integer")

let encode_html_frame (v : html_envelope) =
  match validate_meta v.meta with
  | Error _ as e -> e
  | Ok () -> of_result (Jsont_bytesrw.encode_string ~format:Jsont.Minify html_envelope_jsont v)

let decode_html_frame s = of_result (Jsont_bytesrw.decode_string html_envelope_jsont s)

let encode_canvas_frame (v : canvas_envelope) =
  match validate_meta v.meta with
  | Error _ as e -> e
  | Ok () -> of_result (Jsont_bytesrw.encode_string ~format:Jsont.Minify canvas_envelope_jsont v)

let decode_canvas_frame s = of_result (Jsont_bytesrw.decode_string canvas_envelope_jsont s)
