module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let%expect_test "renderer writes wide cells and wraps before the following glyph" =
  let result =
    let* policy = policy ()
    and* size = size 3 2
    and* lineage_id = uint 3
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 2 0
    and* fourth_coord = coord 0 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x4e00))
           (Model.Update.Batch.singleton (print 0x42)))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord; fourth_coord ])
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+4E00>)
    wide-continuation
    glyph(<U+0042>) |}]

let%expect_test "renderer repairs wide cells touched by character edits" =
  let result =
    let* policy = policy ()
    and* size = size 3 1
    and* lineage_id = uint 3
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 2 0
    and* count = uint 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x4e00))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position first_coord)))
           (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Erase_chars count))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord ])
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    empty
    empty
    empty |}]

let%expect_test "renderer erases display cells" =
  let result =
    let* policy = policy ()
    and* size = size 2 2
    and* lineage_id = uint 7
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 0 1
    and* fourth_coord = coord 1 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (print 0x44))
                 (Model.Update.Batch.append
                    (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position first_coord)))
                    (Model.Update.Batch.singleton (Model.Update.Erase (Model.Update.Display `Clear_below)))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord; fourth_coord ])
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    empty
    empty
    empty
    empty |}]

let%expect_test "renderer edits characters in the active row" =
  let result =
    let* policy = policy ()
    and* size = size 3 1
    and* lineage_id = uint 8
    and* count = uint 1
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 2 0 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position second_coord)))
                 (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Delete_chars count))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord ])
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0043>)
    empty |}]

let%expect_test "renderer deletes active-screen lines" =
  let result =
    let* policy = policy ()
    and* size = size 1 3
    and* lineage_id = uint 9
    and* count = uint 1
    and* first_coord = coord 0 0
    and* second_coord = coord 0 1
    and* third_coord = coord 0 2 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position second_coord)))
                 (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Delete_lines count))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord ])
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0043>)
    empty |}]
