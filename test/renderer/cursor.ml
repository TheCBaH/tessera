module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let%expect_test "snapshot exposes presentation and restored origin state" =
  let result =
    let* policy = policy ()
    and* size = size 4 4
    and* lineage_id = uint 2
    and* top = uint 1
    and* bottom = uint 2
    and* column = uint 0
    and* row = uint 0 in
    let* origin = Option.to_result ~none:"origin mode is unavailable" (Model.Mode.private_mode_delta ~enabled:true 6) in
    let* origin_disabled =
      Option.to_result ~none:"origin mode is unavailable" (Model.Mode.private_mode_delta ~enabled:false 6)
    in
    let* cursor_hidden =
      Option.to_result ~none:"cursor visibility mode is unavailable" (Model.Mode.private_mode_delta ~enabled:false 25)
    in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch =
      List.fold_left
        (fun batch operation -> Model.Update.Batch.append batch (Model.Update.Batch.singleton operation))
        Model.Update.Batch.empty
        [
          Model.Update.Set_margins
            { top = Foundation.Types.Row.of_uint top; bottom = Foundation.Types.Row.of_uint bottom };
          Model.Update.Set_mode origin;
          Model.Update.Move_cursor
            (Model.Update.Position
               (Foundation.Types.coord
                  ~column:(Foundation.Types.Column.of_uint column)
                  ~row:(Foundation.Types.Row.of_uint row)));
          Model.Update.Save_cursor;
          Model.Update.Set_mode cursor_hidden;
          Model.Update.Set_mode origin_disabled;
          Model.Update.Move_cursor (Model.Update.Down Foundation.UInt.max_value);
          Model.Update.Restore_cursor;
          Model.Update.Move_cursor (Model.Update.Down Foundation.UInt.max_value);
          Model.Update.Set_title "tessera";
        ]
    in
    Result.map Renderer.Renderer.snapshot
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_snapshot) result;
  [%expect
    {| snapshot(active=primary; cursor=((0,2); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=false; lineage=2; generation=1; size=4×4; title=some("tessera")) |}]

let%expect_test "renderer honors disabled auto-wrap" =
  let result =
    let* policy = policy ()
    and* size = size 2 2
    and* lineage_id = uint 6
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0 in
    let* auto_wrap = Option.to_result ~none:"missing auto-wrap mode" (Model.Mode.private_mode_delta ~enabled:false 7) in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Set_mode auto_wrap))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x41))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x42))
              (Model.Update.Batch.singleton (print 0x43))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord ])
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0043>) |}]

let%expect_test "renderer uses configured tab stops" =
  let result =
    let* policy = policy ()
    and* size = size 10 1
    and* lineage_id = uint 11
    and* count = uint 1
    and* origin = coord 0 0
    and* target = coord 1 0 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x58)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Forward count)))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton Model.Update.Set_tab)
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Column origin.column)))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton Model.Update.Horizontal_tab)
                 (Model.Update.Batch.singleton print))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells target))
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0058>) |}]
