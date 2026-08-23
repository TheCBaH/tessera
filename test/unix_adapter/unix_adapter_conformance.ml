(* Replays test/conformance's reusable fixture against the real Unix scheduler adapter reading
   from an OS pipe on a background thread, and checks its final rendered content against the
   reference driver's. Scenario.Backpressure_pause/resume carry nothing to deliver on a real
   descriptor (they are pure flow control even for a real adapter) and Scenario.Failure isn't
   meaningfully reproducible on a plain pipe, so those two scenarios are exercised directly below
   instead of through this generic replay. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
module Scenario = Tessera_test_conformance.Scenario
module Reference = Tessera_test_conformance.Reference
module Unix_adapter = Tessera_unix.Unix_adapter
open Tessera_test_support.Support

let cells_of outcome =
  Format.asprintf "%a" Model.Collection.Snapshot_cells.pp (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome))

let replay_via_unix_adapter (scenario : Scenario.scenario) =
  let* policy = policy () and* initial_size = size scenario.columns scenario.rows and* lineage_id = uint 1 in
  let adapter = Unix_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size in
  let read_fd, write_fd = Unix.pipe ~cloexec:true () in
  let last_outcome = ref None in
  let failure = ref None in
  let reader =
    Thread.create
      (fun () ->
        Unix_adapter.run adapter read_fd ~read_buffer_bytes:4096
          ~on_outcome:(fun outcome -> last_outcome := Some outcome)
          ~on_error:(fun error -> failure := Some (Format.asprintf "%a" Unix_adapter.pp_error (Err.Error.kind error))))
      ()
  in
  let write text = ignore (Unix.write_substring write_fd text 0 (String.length text)) in
  List.iter
    (function
      | Scenario.Write text -> write text
      | Scenario.Short_write pieces -> List.iter write pieces
      | Scenario.Backpressure_pause | Scenario.Backpressure_resume -> ()
      | Scenario.Failure _ -> ()
      | Scenario.Resize (columns, rows) -> ignore (Unix_adapter.resize adapter ~columns ~rows)
      | Scenario.Coalesced_resize sizes ->
          let columns, rows = List.nth sizes (List.length sizes - 1) in
          ignore (Unix_adapter.resize adapter ~columns ~rows)
      | Scenario.Eof -> Unix.close write_fd)
    scenario.events;
  Thread.join reader;
  match !failure with
  | Some message -> Error message
  | None -> ( match !last_outcome with Some outcome -> Ok (cells_of outcome) | None -> Error "no outcome observed")

let check (scenario : Scenario.scenario) (reference : Scenario.scenario) =
  let* actual = replay_via_unix_adapter scenario in
  let* expected = Reference.run reference in
  match expected.last_outcome with
  | Some expected_outcome -> Ok (actual = cells_of expected_outcome)
  | None -> Error "reference scenario produced no outcome"

let%expect_test "the Unix adapter reaches the same content as the reference driver: ordered ingress" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.ordered_ingress Scenario.ordered_ingress);
  [%expect {| true |}]

let%expect_test "the Unix adapter reaches the same content as the reference driver: short writes" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.short_writes Scenario.short_writes_reference);
  [%expect {| true |}]

let%expect_test "the Unix adapter reaches the same content as the reference driver: distinct-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.distinct_size_resize Scenario.distinct_size_resize);
  [%expect {| true |}]

let%expect_test "the Unix adapter reaches the same content as the reference driver: equal-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.equal_size_resize Scenario.equal_size_resize);
  [%expect {| true |}]

let%expect_test "the Unix adapter reaches the same content as the reference driver: coalesced resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.coalesced_resize Scenario.coalesced_resize);
  [%expect {| true |}]

let%expect_test "resize rejects a negative row or column count" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 2 in
    let adapter = Unix_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    Result.map
      (fun _ -> "unexpectedly succeeded")
      (with_error_kind Unix_adapter.pp_error (Unix_adapter.resize adapter ~columns:(-1) ~rows:2))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-count(negative(-1)) |}]

let%expect_test "a read failure on a closed descriptor is reported, not raised" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 3 in
    let adapter = Unix_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let read_fd, write_fd = Unix.pipe ~cloexec:true () in
    Unix.close read_fd;
    Unix.close write_fd;
    Result.map
      (fun _ -> "unexpectedly succeeded")
      (with_error_kind Unix_adapter.pp_error (Unix_adapter.read_step adapter read_fd (Bytes.create 16)))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| read-failed(read(): Bad file descriptor) |}]
