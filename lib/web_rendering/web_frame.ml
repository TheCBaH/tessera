open Tessera_foundation
module Style = Tessera_model.Style
module Cell = Tessera_model.Cell
module Unicode = Tessera_model.Unicode
module Collection = Tessera_model.Collection
module Renderer = Tessera_renderer.Renderer
module Patch = Tessera_renderer.Patch

type kind = Reset | Delta
type background_span = { start : Types.Column.t; stop : Types.Column.t; style : Style.t }
type glyph = { start : Types.Column.t; width : Unicode.width; text : string; style : Style.t }
type row = { index : Types.Row.t; background : background_span list; glyphs : glyph list }

type presentation = {
  active : Types.screen;
  cursor_position : Types.coord;
  cursor_pending_wrap : bool;
  cursor_style : Style.t;
  cursor_visible : bool;
  title : string option;
  size : Types.Size.t;
  generation : Generation.t;
  lineage_id : Lineage_id.t;
}

type t = { kind : kind; rows : row list; presentation : presentation }

type error =
  [ `Background_gap of Types.Row.t
  | `Background_invalid_span of Types.Row.t
  | `Background_overlap of Types.Row.t
  | `Duplicate_row of Types.Row.t
  | `Glyph_out_of_range of Types.coord
  | `Glyph_overlap of Types.coord
  | `Incomplete_reset of Types.Row.t
  | `Row_out_of_range of Types.Row.t
  | `Unpaired_wide_glyph of Types.coord ]

let pp_error ppf = function
  | `Background_gap row -> Format.fprintf ppf "background-gap(row=%a)" Types.Row.pp row
  | `Background_invalid_span row -> Format.fprintf ppf "background-invalid-span(row=%a)" Types.Row.pp row
  | `Background_overlap row -> Format.fprintf ppf "background-overlap(row=%a)" Types.Row.pp row
  | `Duplicate_row row -> Format.fprintf ppf "duplicate-row(row=%a)" Types.Row.pp row
  | `Incomplete_reset row -> Format.fprintf ppf "incomplete-reset(missing-row=%a)" Types.Row.pp row
  | `Row_out_of_range row -> Format.fprintf ppf "row-out-of-range(row=%a)" Types.Row.pp row
  | `Glyph_out_of_range c -> Format.fprintf ppf "glyph-out-of-range(%a)" Types.pp_coord c
  | `Glyph_overlap c -> Format.fprintf ppf "glyph-overlap(%a)" Types.pp_coord c
  | `Unpaired_wide_glyph c -> Format.fprintf ppf "unpaired-wide-glyph(%a)" Types.pp_coord c

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let pp_kind ppf = function Reset -> Format.pp_print_string ppf "reset" | Delta -> Format.pp_print_string ppf "delta"

let pp_background_span ppf (v : background_span) =
  Format.fprintf ppf "background(start=%a; stop=%a; style=%a)" Types.Column.pp v.start Types.Column.pp v.stop Style.pp
    v.style

let pp_glyph ppf (v : glyph) =
  Format.fprintf ppf "glyph(start=%a; width=%a; text=%S; style=%a)" Types.Column.pp v.start Unicode.pp_width v.width
    v.text Style.pp v.style

let pp_row ppf (v : row) =
  let pp_list pp = Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") pp in
  Format.fprintf ppf "row(index=%a; background=[%a]; glyphs=[%a])" Types.Row.pp v.index (pp_list pp_background_span)
    v.background (pp_list pp_glyph) v.glyphs

let pp_presentation ppf (v : presentation) =
  let pp_title ppf = function None -> Format.pp_print_string ppf "none" | Some s -> Format.fprintf ppf "some(%S)" s in
  Format.fprintf ppf
    "presentation(active=%a; cursor=(%a; pending-wrap=%b; style=%a); cursor-visible=%b; title=%a; size=%a; \
     generation=%a; lineage=%a)"
    Types.pp_screen v.active Types.pp_coord v.cursor_position v.cursor_pending_wrap Style.pp v.cursor_style
    v.cursor_visible pp_title v.title Types.Size.pp v.size Generation.pp v.generation Lineage_id.pp v.lineage_id

let pp ppf (v : t) =
  let pp_list pp = Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") pp in
  Format.fprintf ppf "frame(kind=%a; rows=[%a]; presentation=%a)" pp_kind v.kind (pp_list pp_row) v.rows pp_presentation
    v.presentation

(* --- geometry helpers --- *)

let uint_exn i = match UInt.of_int i with Ok u -> u | Error _ -> assert false
let column_of_int i = Types.Column.of_uint (uint_exn i)
let row_of_int i = Types.Row.of_uint (uint_exn i)
let column_int c = UInt.to_int (Types.Column.to_uint c)
let row_int r = UInt.to_int (Types.Row.to_uint r)

let color_equal a b =
  match (a, b) with
  | Style.Default, Style.Default -> true
  | Style.Indexed a, Style.Indexed b -> Style.Palette_index.to_int a = Style.Palette_index.to_int b
  | Style.Rgb a, Style.Rgb b ->
      Style.Rgb.red a = Style.Rgb.red b && Style.Rgb.green a = Style.Rgb.green b && Style.Rgb.blue a = Style.Rgb.blue b
  | _ -> false

let rendition_equal (a : Style.rendition) (b : Style.rendition) =
  a.bold = b.bold && a.faint = b.faint && a.invisible = b.invisible && a.inverse = b.inverse && a.italic = b.italic
  && a.strikethrough = b.strikethrough && a.underline = b.underline

let style_equal (a : Style.t) (b : Style.t) =
  color_equal a.background b.background && color_equal a.foreground b.foreground
  && rendition_equal a.rendition b.rendition

let glyph_width_columns = function Unicode.One | Unicode.Zero -> 1 | Unicode.Two -> 2

(* --- rows_of_cells --- *)

exception Unpaired_wide_glyph of Types.coord

let build_row cells columns row_index =
  let row_t = row_of_int row_index in
  let get c = Collection.Snapshot_cells.get cells (Types.coord ~column:(column_of_int c) ~row:row_t) in
  let background =
    let acc = ref [] in
    let seg_start = ref 0 in
    let seg_style = ref (Cell.style (get 0)) in
    for c = 1 to columns - 1 do
      let s = Cell.style (get c) in
      if not (style_equal s !seg_style) then begin
        acc := { start = column_of_int !seg_start; stop = column_of_int c; style = !seg_style } :: !acc;
        seg_start := c;
        seg_style := s
      end
    done;
    acc := { start = column_of_int !seg_start; stop = column_of_int columns; style = !seg_style } :: !acc;
    List.rev !acc
  in
  let glyphs =
    let acc = ref [] in
    let c = ref 0 in
    while !c < columns do
      let cell = get !c in
      (match Cell.contents cell with
      | Cell.Empty | Cell.Wide_continuation -> ()
      | Cell.Glyph g ->
          let width = Unicode.width g in
          (match width with
          | Unicode.Two ->
              let paired = !c + 1 < columns && Cell.contents (get (!c + 1)) = Cell.Wide_continuation in
              if not paired then raise (Unpaired_wide_glyph (Types.coord ~column:(column_of_int !c) ~row:row_t))
          | Unicode.One | Unicode.Zero -> ());
          acc := { start = column_of_int !c; width; text = Unicode.utf8 g; style = Cell.style cell } :: !acc);
      incr c
    done;
    List.rev !acc
  in
  { index = row_t; background; glyphs }

let rows_of_cells cells =
  let size = Collection.Snapshot_cells.size cells in
  let columns = UInt.to_int (Types.Size.columns size) in
  let rows = UInt.to_int (Types.Size.rows size) in
  try Ok (List.init rows (build_row cells columns)) with Unpaired_wide_glyph c -> E.fail (`Unpaired_wide_glyph c)

(* --- of_outcome --- *)

let presentation_of_snapshot snapshot =
  let cursor = Renderer.cursor snapshot in
  {
    active = Renderer.active snapshot;
    cursor_position = cursor.Renderer.position;
    cursor_pending_wrap = cursor.Renderer.pending_wrap;
    cursor_style = cursor.Renderer.style;
    cursor_visible = Renderer.cursor_visible snapshot;
    title = Renderer.title snapshot;
    size = Renderer.size snapshot;
    generation = Renderer.generation snapshot;
    lineage_id = Renderer.lineage_id snapshot;
  }

let damaged_row_flags ~rows damage =
  let flags = Array.make rows false in
  Collection.Damage.fold_left
    (fun () rect ->
      let top = row_int (Types.rect_top rect) and bottom = row_int (Types.rect_bottom rect) in
      for r = max 0 top to min (rows - 1) bottom do
        flags.(r) <- true
      done)
    () damage;
  flags

let of_outcome ~patch ~snapshot =
  let open Err.Syntax in
  let presentation = presentation_of_snapshot snapshot in
  let reset () =
    let+ rows = rows_of_cells (Renderer.cells snapshot) in
    { kind = Reset; rows; presentation }
  in
  match patch with
  | None -> reset ()
  | Some p -> (
      let active_changed = match (Patch.presentation p).active with Patch.Set _ -> true | Patch.Keep -> false in
      let size_changed = match Patch.size p with Patch.Set _ -> true | Patch.Keep -> false in
      match active_changed || size_changed with
      | true -> reset ()
      | false ->
          let* all_rows = rows_of_cells (Renderer.cells snapshot) in
          let rows_n = UInt.to_int (Types.Size.rows presentation.size) in
          let flags = damaged_row_flags ~rows:rows_n (Patch.damage p) in
          let rows = List.filter (fun row -> flags.(row_int row.index)) all_rows in
          Ok { kind = Delta; rows; presentation })

(* --- validate --- *)

exception Invalid of error

let check_row_background columns (row : row) =
  let expect = ref 0 in
  List.iter
    (fun (span : background_span) ->
      let s = column_int span.start and e = column_int span.stop in
      if s > e || e > columns then raise (Invalid (`Background_invalid_span row.index));
      if s > !expect then raise (Invalid (`Background_gap row.index))
      else if s < !expect then raise (Invalid (`Background_overlap row.index));
      expect := e)
    row.background;
  if !expect <> columns then raise (Invalid (`Background_gap row.index))

let check_row_glyphs columns (row : row) =
  let cursor = ref 0 in
  List.iter
    (fun (g : glyph) ->
      let s = column_int g.start in
      let w = glyph_width_columns g.width in
      if s < !cursor then raise (Invalid (`Glyph_overlap (Types.coord ~column:g.start ~row:row.index)));
      (* [s > columns || w > columns - s], not [s + w > columns]: [Types.Column.t] is an unchecked non-negative
         [int], so a hand-built frame's [s + w] can wrap negative on native OCaml for [s] near [max_int] and slip
         past an addition-based check. Checking [s <= columns] first means the subtraction below never underflows,
         so [s + w] (computed only afterwards, now provably [<= columns]) is safe to store as the next cursor. *)
      if s > columns || w > columns - s then
        raise (Invalid (`Glyph_out_of_range (Types.coord ~column:g.start ~row:row.index)));
      cursor := s + w)
    row.glyphs

let validate t =
  let columns = UInt.to_int (Types.Size.columns t.presentation.size) in
  let rows_n = UInt.to_int (Types.Size.rows t.presentation.size) in
  let seen = Array.make rows_n false in
  try
    List.iter
      (fun row ->
        let idx = row_int row.index in
        if idx >= rows_n then raise (Invalid (`Row_out_of_range row.index));
        if seen.(idx) then raise (Invalid (`Duplicate_row row.index));
        seen.(idx) <- true;
        check_row_background columns row;
        check_row_glyphs columns row)
      t.rows;
    (match t.kind with
    | Reset ->
        for i = 0 to rows_n - 1 do
          if not seen.(i) then raise (Invalid (`Incomplete_reset (row_of_int i)))
        done
    | Delta -> ());
    Ok ()
  with Invalid e -> E.fail e
