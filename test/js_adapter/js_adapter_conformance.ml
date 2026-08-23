(* Replays test/conformance's reusable fixture against the real push-style JS-host adapter, mirroring
   test/unix_adapter, test/lwt_adapter, and test/async_adapter. Unlike those three, there is no descriptor or
   scheduler to drive: push/resize/finish are plain synchronous functions, so each scenario event translates
   directly to one call instead of a background reader plus interleaved writes. Scenario.Backpressure_pause/resume
   carry nothing to deliver to a function-call interface and Scenario.Failure has no analogue -- this adapter has no
   I/O layer that can fail, only the same typed validation failures {!Js_adapter.resize} always has -- so those
   scenarios contribute no events here beyond what ordinary replay already covers. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
module Scenario = Tessera_test_conformance.Scenario
module Reference = Tessera_test_conformance.Reference
module Js_adapter = Tessera_js_adapter.Js_adapter
open Tessera_test_support.Support

let cells_of outcome =
  Format.asprintf "%a" Model.Collection.Snapshot_cells.pp (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome))

let replay_via_js_adapter (scenario : Scenario.scenario) =
  let* policy = policy () and* initial_size = size scenario.columns scenario.rows and* lineage_id = uint 1 in
  let adapter = Js_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size in
  let last_outcome = ref None in
  let failure = ref None in
  let record = function
    | Ok outcome -> last_outcome := Some outcome
    | Error error ->
        if !failure = None then failure := Some (Format.asprintf "%a" Js_adapter.pp_error (Err.Error.kind error))
  in
  List.iter
    (function
      | Scenario.Write text -> record (Js_adapter.push adapter text)
      | Scenario.Short_write pieces -> List.iter (fun text -> record (Js_adapter.push adapter text)) pieces
      | Scenario.Backpressure_pause | Scenario.Backpressure_resume | Scenario.Failure _ -> ()
      | Scenario.Resize (columns, rows) -> record (Js_adapter.resize adapter ~columns ~rows)
      | Scenario.Coalesced_resize sizes ->
          let columns, rows = List.nth sizes (List.length sizes - 1) in
          record (Js_adapter.resize adapter ~columns ~rows)
      | Scenario.Eof -> record (Js_adapter.finish adapter))
    scenario.events;
  match !failure with
  | Some message -> Error message
  | None -> ( match !last_outcome with Some outcome -> Ok (cells_of outcome) | None -> Error "no outcome observed")

let check (scenario : Scenario.scenario) (reference : Scenario.scenario) =
  let* actual = replay_via_js_adapter scenario in
  let* expected = Reference.run reference in
  match expected.last_outcome with
  | Some expected_outcome -> Ok (actual = cells_of expected_outcome)
  | None -> Error "reference scenario produced no outcome"

let%expect_test "the JS-host adapter reaches the same content as the reference driver: ordered ingress" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.ordered_ingress Scenario.ordered_ingress);
  [%expect {| true |}]

let%expect_test "the JS-host adapter reaches the same content as the reference driver: short writes" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.short_writes Scenario.short_writes_reference);
  [%expect {| true |}]

let%expect_test "the JS-host adapter reaches the same content as the reference driver: distinct-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.distinct_size_resize Scenario.distinct_size_resize);
  [%expect {| true |}]

let%expect_test "the JS-host adapter reaches the same content as the reference driver: equal-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.equal_size_resize Scenario.equal_size_resize);
  [%expect {| true |}]

let%expect_test "the JS-host adapter reaches the same content as the reference driver: coalesced resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.coalesced_resize Scenario.coalesced_resize);
  [%expect {| true |}]

let%expect_test "resize rejects a negative row or column count" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 2 in
    let adapter = Js_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    Result.map
      (fun _ -> "unexpectedly succeeded")
      (with_error_kind Js_adapter.pp_error (Js_adapter.resize adapter ~columns:(-1) ~rows:2))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-count(negative(-1)) |}]
