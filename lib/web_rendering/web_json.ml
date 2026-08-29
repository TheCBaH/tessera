module Frame = Web_frame
module Html = Web_html
module Canvas = Web_canvas
module Types = Tessera_foundation.Types

let invalid what = Jsont.Error.msg Jsont.Meta.none ("invalid " ^ what)

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
      | "var", Some n, None -> Html.Var n | "hex", None, Some v -> Html.Hex v | _ -> invalid "html colour value")
    ~enc:(function Html.Var n -> ("var", Some n, None) | Html.Hex v -> ("hex", None, Some v))

let html_style_jsont =
  Jsont.Object.map (fun fg bg classes -> { Html.fg; bg; classes })
  |> Jsont.Object.mem "fg" html_color_value_jsont ~enc:(fun (s : Html.style) -> s.fg)
  |> Jsont.Object.mem "bg" html_color_value_jsont ~enc:(fun (s : Html.style) -> s.bg)
  |> Jsont.Object.mem "classes" (Jsont.list Jsont.string) ~enc:(fun (s : Html.style) -> s.classes)
  |> Jsont.Object.finish

let html_background_span_jsont =
  Jsont.Object.map (fun start width style -> { Html.start; width; style })
  |> Jsont.Object.mem "start" Jsont.int ~enc:(fun (v : Html.background_span) -> v.start)
  |> Jsont.Object.mem "width" Jsont.int ~enc:(fun (v : Html.background_span) -> v.width)
  |> Jsont.Object.mem "style" html_style_jsont ~enc:(fun (v : Html.background_span) -> v.style)
  |> Jsont.Object.finish

let html_glyph_span_jsont =
  Jsont.Object.map (fun start width text style -> { Html.start; width; text; style })
  |> Jsont.Object.mem "start" Jsont.int ~enc:(fun (v : Html.glyph_span) -> v.start)
  |> Jsont.Object.mem "width" Jsont.int ~enc:(fun (v : Html.glyph_span) -> v.width)
  |> Jsont.Object.mem "text" Jsont.string ~enc:(fun (v : Html.glyph_span) -> v.text)
  |> Jsont.Object.mem "style" html_style_jsont ~enc:(fun (v : Html.glyph_span) -> v.style)
  |> Jsont.Object.finish

let html_row_jsont =
  Jsont.Object.map (fun index background glyphs -> { Html.index; background; glyphs })
  |> Jsont.Object.mem "index" Jsont.int ~enc:(fun (v : Html.row) -> v.index)
  |> Jsont.Object.mem "background" (Jsont.list html_background_span_jsont) ~enc:(fun (v : Html.row) -> v.background)
  |> Jsont.Object.mem "glyphs" (Jsont.list html_glyph_span_jsont) ~enc:(fun (v : Html.row) -> v.glyphs)
  |> Jsont.Object.finish

let html_cursor_jsont =
  Jsont.Object.map (fun column row visible pending_wrap style -> { Html.column; row; visible; pending_wrap; style })
  |> Jsont.Object.mem "column" Jsont.int ~enc:(fun (v : Html.cursor) -> v.column)
  |> Jsont.Object.mem "row" Jsont.int ~enc:(fun (v : Html.cursor) -> v.row)
  |> Jsont.Object.mem "visible" Jsont.bool ~enc:(fun (v : Html.cursor) -> v.visible)
  |> Jsont.Object.mem "pending_wrap" Jsont.bool ~enc:(fun (v : Html.cursor) -> v.pending_wrap)
  |> Jsont.Object.mem "style" html_style_jsont ~enc:(fun (v : Html.cursor) -> v.style)
  |> Jsont.Object.finish

let html_frame_jsont =
  Jsont.Object.map (fun rows cursor accessible_text -> { Html.rows; cursor; accessible_text })
  |> Jsont.Object.mem "rows" (Jsont.list html_row_jsont) ~enc:(fun (v : Html.t) -> v.rows)
  |> Jsont.Object.mem "cursor" html_cursor_jsont ~enc:(fun (v : Html.t) -> v.cursor)
  |> Jsont.Object.mem "accessible_text" Jsont.string ~enc:(fun (v : Html.t) -> v.accessible_text)
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
      | "indexed", Some i, None, None, None -> Canvas.Indexed i
      | "rgb", None, Some r, Some g, Some b -> Canvas.Rgb (r, g, b)
      | _ -> invalid "canvas colour")
    ~enc:(function
      | Canvas.Default -> ("default", None, None, None, None)
      | Canvas.Indexed i -> ("indexed", Some i, None, None, None)
      | Canvas.Rgb (r, g, b) -> ("rgb", None, Some r, Some g, Some b))

let canvas_paint_jsont =
  Jsont.Object.map (fun color bold italic opacity -> { Canvas.color; bold; italic; opacity })
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
  Jsont.map obj
    ~dec:(fun (op, row, start, width, column, text, visible, color, paint) ->
      match (op, start, width, column, text, visible, color, paint) with
      | "fill", Some start, Some width, None, None, None, Some color, None -> Canvas.Fill { row; start; width; color }
      | "underline", Some start, Some width, None, None, None, Some color, None ->
          Canvas.Underline { row; start; width; color }
      | "strikethrough", Some start, Some width, None, None, None, Some color, None ->
          Canvas.Strikethrough { row; start; width; color }
      | "glyph", None, None, Some column, Some text, None, None, Some paint -> Canvas.Glyph { row; column; text; paint }
      | "cursor", None, None, Some column, None, Some visible, Some color, None ->
          Canvas.Cursor { row; column; visible; color }
      | _ -> invalid "canvas op")
    ~enc:(function
      | Canvas.Fill v -> ("fill", v.row, Some v.start, Some v.width, None, None, None, Some v.color, None)
      | Canvas.Underline v -> ("underline", v.row, Some v.start, Some v.width, None, None, None, Some v.color, None)
      | Canvas.Strikethrough v ->
          ("strikethrough", v.row, Some v.start, Some v.width, None, None, None, Some v.color, None)
      | Canvas.Glyph v -> ("glyph", v.row, None, None, Some v.column, Some v.text, None, None, Some v.paint)
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

type html_envelope = { schema : string; version : int; meta : meta; frame : Html.t }
type canvas_envelope = { schema : string; version : int; meta : meta; frame : Canvas.t }

let schema = "tessera.web-frame"
let version = 1

let geometry_jsont =
  Jsont.Object.map (fun columns rows -> { columns; rows })
  |> Jsont.Object.mem "columns" Jsont.int ~enc:(fun v -> v.columns)
  |> Jsont.Object.mem "rows" Jsont.int ~enc:(fun v -> v.rows)
  |> Jsont.Object.finish

let meta_jsont =
  Jsont.Object.map (fun kind active geometry generation lineage_id title ->
      { kind; active; geometry; generation; lineage_id; title })
  |> Jsont.Object.mem "kind" kind_jsont ~enc:(fun v -> v.kind)
  |> Jsont.Object.mem "active" screen_jsont ~enc:(fun v -> v.active)
  |> Jsont.Object.mem "geometry" geometry_jsont ~enc:(fun v -> v.geometry)
  |> Jsont.Object.mem "generation" Jsont.string ~enc:(fun v -> v.generation)
  |> Jsont.Object.mem "lineage_id" Jsont.string ~enc:(fun v -> v.lineage_id)
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:(fun v -> v.title)
  |> Jsont.Object.finish

let html_envelope_jsont =
  Jsont.Object.map (fun schema version meta frame : html_envelope -> { schema; version; meta; frame })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun (v : html_envelope) -> v.schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun (v : html_envelope) -> v.version)
  |> Jsont.Object.mem "meta" meta_jsont ~enc:(fun (v : html_envelope) -> v.meta)
  |> Jsont.Object.mem "frame" html_frame_jsont ~enc:(fun (v : html_envelope) -> v.frame)
  |> Jsont.Object.finish

let canvas_envelope_jsont =
  Jsont.Object.map (fun schema version meta frame : canvas_envelope -> { schema; version; meta; frame })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun (v : canvas_envelope) -> v.schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun (v : canvas_envelope) -> v.version)
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
  { schema; version; meta = meta_of_frame frame; frame = Html.of_frame frame }

let canvas_envelope_of frame : canvas_envelope =
  { schema; version; meta = meta_of_frame frame; frame = Canvas.of_frame frame }

type error = [ `Json of string ]

let pp_error ppf (`Json msg) = Format.fprintf ppf "json(%s)" msg

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let of_result = function Ok v -> Ok v | Error msg -> E.fail (`Json msg)
let encode_html_frame v = of_result (Jsont_bytesrw.encode_string ~format:Jsont.Minify html_envelope_jsont v)
let decode_html_frame s = of_result (Jsont_bytesrw.decode_string html_envelope_jsont s)
let encode_canvas_frame v = of_result (Jsont_bytesrw.encode_string ~format:Jsont.Minify canvas_envelope_jsont v)
let decode_canvas_frame s = of_result (Jsont_bytesrw.decode_string canvas_envelope_jsont s)
