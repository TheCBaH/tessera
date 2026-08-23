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

let print scalar =
  Model.Update.Print
    (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))

let apply policy renderer batch =
  with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch)

let columns = 80
let rows = 24
let run_length = 80

(* A grid warmed by one line's worth of printable output, so the later single-operation workloads
   measure the cost of touching a handful of already-allocated pages, not blank-page allocation. *)
let warmed_state policy ~lineage_id ~size =
  let batch = batch_of_updates (List.init run_length (fun index -> print (0x41 + (index mod 26)))) in
  let renderer = Renderer.Renderer.initial ~lineage_id ~policy ~size in
  let* applied = apply policy renderer batch in
  Ok (Renderer.Renderer.state applied)

let printable_run_budget = 40_000_000.

let%expect_test "a printable run stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size columns rows and* lineage_id = uint 6 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch = batch_of_updates (List.init run_length (fun index -> print (0x41 + (index mod 26)))) in
    within_allocation_budget ~label:"printable run within budget" ~maximum:printable_run_budget (fun () ->
        apply policy renderer batch)
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| printable run within budget |}]

let local_edit_budget = 3_000_000.

let%expect_test "a single local edit on a warmed grid stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size columns rows and* lineage_id = uint 7 in
    let* state = warmed_state policy ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~size in
    let edit = Model.Update.Edit (Model.Update.Delete_chars (Foundation.UInt.of_int 1 |> Result.get_ok)) in
    within_allocation_budget ~label:"local edit within budget" ~maximum:local_edit_budget (fun () ->
        apply policy state (Model.Update.Batch.singleton edit))
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| local edit within budget |}]

let scroll_budget = 6_000_000.

let%expect_test "a scroll on a warmed grid stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size columns rows and* lineage_id = uint 8 and* count = uint 1 in
    let* state = warmed_state policy ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~size in
    let scroll = Model.Update.Scroll_up count in
    within_allocation_budget ~label:"scroll within budget" ~maximum:scroll_budget (fun () ->
        apply policy state (Model.Update.Batch.singleton scroll))
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| scroll within budget |}]

(* A same-geometry resize is, by design, a full-projection refresh (terminal-impl.md section 2):
   every cell is re-projected and full damage is reported even when the size is unchanged, so its
   budget is necessarily proportional to the whole grid rather than to the touched region. *)
let resize_refresh_budget = 900_000_000.

let%expect_test "a same-size resize refresh on a warmed grid stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size columns rows and* lineage_id = uint 9 in
    let* state = warmed_state policy ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~size in
    let resize = Model.Update.Resize size in
    within_allocation_budget ~label:"resize refresh within budget" ~maximum:resize_refresh_budget (fun () ->
        apply policy state (Model.Update.Batch.singleton resize))
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| resize refresh within budget |}]

let alternate_screen_switch_budget = 3_000_000.

let%expect_test "an alternate-screen switch on a warmed grid stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size columns rows and* lineage_id = uint 10 in
    let* state = warmed_state policy ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~size in
    let enter = Model.Update.Alternate_screen `Enter_1049 in
    within_allocation_budget ~label:"alternate-screen switch within budget" ~maximum:alternate_screen_switch_budget
      (fun () -> apply policy state (Model.Update.Batch.singleton enter))
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| alternate-screen switch within budget |}]

let snapshot_creation_budget = 50_000.

let%expect_test "creating a snapshot from a warmed applied result stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size columns rows and* lineage_id = uint 11 in
    let* state = warmed_state policy ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~size in
    let* applied = apply policy state (Model.Update.Batch.singleton (print 0x5a)) in
    within_allocation_budget ~label:"snapshot creation within budget" ~maximum:snapshot_creation_budget (fun () ->
        let snapshot = Renderer.Renderer.snapshot applied in
        ignore (Renderer.Renderer.cells snapshot);
        Ok ())
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| snapshot creation within budget |}]
