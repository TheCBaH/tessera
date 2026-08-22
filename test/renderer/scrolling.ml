module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let%expect_test "renderer scrolls immutable grids" =
  let result =
    let* policy = policy ()
    and* size = size 2 2
    and* lineage_id = uint 5
    and* count = uint 1
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
                 (Model.Update.Batch.singleton (Model.Update.Scroll_up count)))))
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
    glyph(<U+0043>)
    glyph(<U+0044>)
    empty
    empty |}]

let%expect_test "renderer scrolls and positions inside explicit margins" =
  let result =
    let* policy = policy ()
    and* size = size 1 4
    and* lineage_id = uint 10
    and* first_coord = coord 0 0
    and* second_coord = coord 0 1
    and* third_coord = coord 0 2
    and* fourth_coord = coord 0 3 in
    let* origin_mode = Option.to_result ~none:"missing origin mode" (Model.Mode.private_mode_delta ~enabled:true 6) in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let margins = { Model.Update.top = second_coord.row; bottom = third_coord.row } in
    let at coordinate update =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position coordinate)))
        (Model.Update.Batch.singleton update)
    in
    let batch =
      Model.Update.Batch.append
        (at first_coord (print 0x41))
        (Model.Update.Batch.append
           (at second_coord (print 0x42))
           (Model.Update.Batch.append
              (at third_coord (print 0x43))
              (Model.Update.Batch.append
                 (at fourth_coord (print 0x44))
                 (Model.Update.Batch.append
                    (Model.Update.Batch.singleton (Model.Update.Set_margins margins))
                    (Model.Update.Batch.append
                       (Model.Update.Batch.singleton (Model.Update.Set_mode origin_mode))
                       (Model.Update.Batch.append
                          (at second_coord (print 0x58))
                          (Model.Update.Batch.singleton (print 0x59))))))))
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
    glyph(<U+0058>)
    glyph(<U+0059>)
    glyph(<U+0044>) |}]
