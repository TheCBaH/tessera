module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let within_allocation_budget ~label ~maximum work =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let* _ = work () in
  let allocated = Gc.allocated_bytes () -. before in
  if allocated <= maximum then Ok label
  else Error (Format.asprintf "%s allocated %.0f bytes (budget %.0f)" label allocated maximum)

let%expect_test "a warmed local renderer update stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size 80 24 and* lineage_id = uint 6 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let work () =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton print))
    in
    within_allocation_budget ~label:"local renderer update within budget" ~maximum:2_000_000. work
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| local renderer update within budget |}]
