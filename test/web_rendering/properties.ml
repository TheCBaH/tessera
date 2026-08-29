module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
module Frame = Tessera_web_rendering.Web_frame
open Tessera_test_support.Support

let uint_exn n = match Foundation.UInt.of_int n with Ok v -> v | Error _ -> assert false
let column_of_int n = Foundation.Types.Column.of_uint (uint_exn n)
let renderer_size = match size 6 3 with Ok s -> s | Error e -> failwith e
let default_policy = match policy () with Ok p -> p | Error e -> failwith e

let printable_gen =
  QCheck.Gen.map
    (fun code ->
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int code))))
    (QCheck.Gen.int_range 0x20 0x7e)

let cr_lf_tab_gen =
  QCheck.Gen.oneof_list
    [
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x0a)));
    ]

let update_gen = QCheck.Gen.oneof_weighted [ (5, printable_gen); (1, cr_lf_tab_gen) ]
let updates_gen = QCheck.Gen.list_size (QCheck.Gen.int_bound 20) update_gen

let batch_of updates =
  List.fold_left
    (fun batch update -> Model.Update.Batch.append batch (Model.Update.Batch.singleton update))
    Model.Update.Batch.empty updates

(* Independent projection-verifier: reconstructs per-column (style, glyph-text) from the emitted row
   instructions and compares against the source snapshot cells directly, without going through any of
   Web_frame's own construction logic. *)
let style_equal (a : Model.Style.t) (b : Model.Style.t) =
  let color_equal a b =
    match (a, b) with
    | Model.Style.Default, Model.Style.Default -> true
    | Model.Style.Indexed a, Model.Style.Indexed b ->
        Model.Style.Palette_index.to_int a = Model.Style.Palette_index.to_int b
    | Model.Style.Rgb a, Model.Style.Rgb b ->
        Model.Style.Rgb.red a = Model.Style.Rgb.red b
        && Model.Style.Rgb.green a = Model.Style.Rgb.green b
        && Model.Style.Rgb.blue a = Model.Style.Rgb.blue b
    | _ -> false
  in
  color_equal a.background b.background && color_equal a.foreground b.foreground && a.rendition = b.rendition

let verify_row cells ~columns (row : Frame.row) =
  let styles = Array.make columns None in
  List.iter
    (fun (s : Frame.background_span) ->
      for
        c = Foundation.UInt.to_int (Foundation.Types.Column.to_uint s.start)
        to Foundation.UInt.to_int (Foundation.Types.Column.to_uint s.stop) - 1
      do
        styles.(c) <- Some s.style
      done)
    row.background;
  let glyph_at = Array.make columns None in
  List.iter
    (fun (g : Frame.glyph) -> glyph_at.(Foundation.UInt.to_int (Foundation.Types.Column.to_uint g.start)) <- Some g)
    row.glyphs;
  let ok = ref true in
  for c = 0 to columns - 1 do
    let cell =
      Model.Collection.Snapshot_cells.get cells (Foundation.Types.coord ~column:(column_of_int c) ~row:row.index)
    in
    (match styles.(c) with
    | None -> ok := false
    | Some s -> if not (style_equal s (Model.Cell.style cell)) then ok := false);
    match (glyph_at.(c), Model.Cell.contents cell) with
    | Some g, Model.Cell.Glyph grapheme -> if g.text <> Model.Unicode.utf8 grapheme then ok := false
    | Some _, _ -> ok := false
    | None, Model.Cell.Glyph _ -> ok := false
    | None, (Model.Cell.Empty | Model.Cell.Wide_continuation) -> ()
  done;
  !ok

let verify_frame cells (frame : Frame.t) =
  let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns frame.presentation.size) in
  List.for_all (verify_row cells ~columns) frame.rows

let arbitrary = QCheck.make updates_gen ~print:(fun updates -> Printf.sprintf "updates=%d" (List.length updates))

let of_outcome_always_validates =
  QCheck.Test.make ~count:300 ~name:"Web_frame.of_outcome output always validates" arbitrary (fun updates ->
      let initial =
        Renderer.Renderer.initial
          ~lineage_id:(Foundation.Lineage_id.of_uint (uint_exn 1))
          ~policy:default_policy ~size:renderer_size
      in
      match Renderer.Renderer.apply default_policy initial (batch_of updates) with
      | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
      | Ok applied -> (
          let snapshot = Renderer.Renderer.snapshot applied in
          let patch = Renderer.Renderer.patch applied in
          match (Frame.of_outcome ~patch:None ~snapshot, Frame.of_outcome ~patch:(Some patch) ~snapshot) with
          | Ok reset, Ok delta -> Result.is_ok (Frame.validate reset) && Result.is_ok (Frame.validate delta)
          | _ -> QCheck.Test.fail_report "of_outcome reported an error for a real renderer snapshot"))

let reset_frame_matches_snapshot =
  QCheck.Test.make ~count:300 ~name:"a reset frame is content-equivalent to its source snapshot" arbitrary
    (fun updates ->
      let initial =
        Renderer.Renderer.initial
          ~lineage_id:(Foundation.Lineage_id.of_uint (uint_exn 2))
          ~policy:default_policy ~size:renderer_size
      in
      match Renderer.Renderer.apply default_policy initial (batch_of updates) with
      | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
      | Ok applied -> (
          let snapshot = Renderer.Renderer.snapshot applied in
          match Frame.of_outcome ~patch:None ~snapshot with
          | Ok frame -> verify_frame (Renderer.Renderer.cells snapshot) frame
          | Error _ -> QCheck.Test.fail_report "of_outcome reported an error for a real renderer snapshot"))

let generation_is_monotonic =
  QCheck.Test.make ~count:200 ~name:"presentation generation never regresses across successive applies"
    (QCheck.pair arbitrary arbitrary) (fun (first, second) ->
      let initial =
        Renderer.Renderer.initial
          ~lineage_id:(Foundation.Lineage_id.of_uint (uint_exn 3))
          ~policy:default_policy ~size:renderer_size
      in
      match Renderer.Renderer.apply default_policy initial (batch_of first) with
      | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
      | Ok applied_first -> (
          match Renderer.Renderer.apply default_policy (Renderer.Renderer.state applied_first) (batch_of second) with
          | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
          | Ok applied_second -> (
              match
                ( Frame.of_outcome ~patch:None ~snapshot:(Renderer.Renderer.snapshot applied_first),
                  Frame.of_outcome ~patch:None ~snapshot:(Renderer.Renderer.snapshot applied_second) )
              with
              | Ok before, Ok after ->
                  Foundation.Generation.compare before.presentation.generation after.presentation.generation <= 0
              | _ -> QCheck.Test.fail_report "of_outcome reported an error for a real renderer snapshot")))

let tests = [ of_outcome_always_validates; reset_frame_matches_snapshot; generation_is_monotonic ]
let () = QCheck_base_runner.run_tests_main tests
