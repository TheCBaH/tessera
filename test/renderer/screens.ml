module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let%expect_test "renderer exposes precise local and full resize damage" =
  let result =
    let* policy = policy () and* initial_size = size 2 1 and* resized_size = size 2 2 and* lineage = uint 1 in
    let renderer =
      Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size:initial_size
    in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let* printed =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton print))
    in
    let* resized =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy (Renderer.Renderer.state printed)
           (Model.Update.Batch.singleton (Model.Update.Resize resized_size)))
    in
    Ok (Renderer.Renderer.damage printed, Renderer.Renderer.damage resized)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Renderer.Renderer.pp_damage Renderer.Renderer.pp_damage)) result;
  [%expect
    {|
    damage(cursor-changed=true; full=false; rects=[{top=0; left=0; bottom=0; right=0}])
    damage(cursor-changed=false; full=true; rects=[{top=0; left=0; bottom=1; right=1}]) |}]

let%expect_test "snapshot materializes the active grid" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage_id = uint 1 and* coordinate = coord 0 0 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch =
      Model.Update.Batch.singleton
        (Model.Update.Print
           (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0041>) |}]

let%expect_test "renderer restores the primary cursor around DEC 1049" =
  let result =
    let* policy = policy () and* size = size 3 1 and* lineage_id = uint 3 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      List.fold_left
        (fun batch operation -> Model.Update.Batch.append batch (Model.Update.Batch.singleton operation))
        Model.Update.Batch.empty
        [ print 0x41; Model.Update.Alternate_screen `Enter_1049; print 0x42; Model.Update.Alternate_screen `Leave_1049 ]
    in
    Result.map Renderer.Renderer.snapshot
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_snapshot) result;
  [%expect
    {| snapshot(active=primary; cursor=((1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=true; lineage=3; generation=1; size=3×1; title=none) |}]
