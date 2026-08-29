module Foundation = Tessera_foundation
module Model = Tessera_model
module Web = Tessera_web_rendering.Web_frame
open Tessera_test_support.Support

let style = Model.Style.default
let line_id = Foundation.Line_id.zero
let wide_grapheme = Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x4e00)

let cells_of size row =
  let* size = size in
  match Model.Collection.Snapshot_cells.of_row_major ~size (Array.of_list row) with
  | Some cells -> Ok cells
  | None -> Error "of_row_major rejected the row"

let%expect_test "rows_of_cells accepts a correctly paired wide glyph" =
  let result =
    let* cells =
      cells_of (size 3 1)
        [
          Model.Cell.glyph ~line_id ~style wide_grapheme;
          Model.Cell.wide_continuation ~line_id ~style;
          Model.Cell.blank ~line_id ~style;
        ]
    in
    with_error_kind Web.pp_error (Web.rows_of_cells cells)
  in
  Format.printf "%a@." (pp_result (Fmt.list Web.pp_row)) result;
  [%expect
    {| row(index=0; background=[background(start=0; stop=3; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false})]; glyphs=[glyph(start=0; width=two; text="\228\184\128"; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false})]) |}]

let%expect_test "rows_of_cells rejects a wide glyph not followed by Wide_continuation" =
  let result =
    let* cells =
      cells_of (size 3 1)
        [
          Model.Cell.glyph ~line_id ~style wide_grapheme;
          Model.Cell.blank ~line_id ~style;
          Model.Cell.blank ~line_id ~style;
        ]
    in
    with_error_kind Web.pp_error (Web.rows_of_cells cells)
  in
  Format.printf "%a@." (pp_result (Fmt.list Web.pp_row)) result;
  [%expect {| unpaired-wide-glyph((0,0)) |}]

let%expect_test "rows_of_cells rejects a wide glyph at the last column with no room for a continuation" =
  let result =
    let* cells =
      cells_of (size 2 1) [ Model.Cell.blank ~line_id ~style; Model.Cell.glyph ~line_id ~style wide_grapheme ]
    in
    with_error_kind Web.pp_error (Web.rows_of_cells cells)
  in
  Format.printf "%a@." (pp_result (Fmt.list Web.pp_row)) result;
  [%expect {| unpaired-wide-glyph((1,0)) |}]
