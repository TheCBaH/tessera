(* Replays test/conformance's reusable fixture against the real Lwt scheduler adapter reading from an OS pipe
   concurrently with the writer, all on one Lwt event loop. Scenario.Backpressure_pause/resume carry nothing to
   deliver on a real descriptor (they are pure flow control even for a real adapter) and Scenario.Failure isn't
   meaningfully reproducible on a plain pipe, so those two scenarios are exercised directly below instead of through
   this generic replay -- mirroring test/unix_adapter. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
module Scenario = Tessera_test_conformance.Scenario
module Reference = Tessera_test_conformance.Reference
module Lwt_adapter = Tessera_lwt.Lwt_adapter
open Tessera_test_support.Support

let cells_of outcome =
  Format.asprintf "%a" Model.Collection.Snapshot_cells.pp (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome))

let replay_via_lwt_adapter (scenario : Scenario.scenario) =
  let* policy = policy () and* initial_size = size scenario.columns scenario.rows and* lineage_id = uint 1 in
  let adapter = Lwt_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size in
  let read_fd, write_fd = Lwt_unix.pipe ~cloexec:true () in
  let last_outcome = ref None in
  let failure = ref None in
  let reader =
    Lwt_adapter.run adapter read_fd ~read_buffer_bytes:4096
      ~on_outcome:(fun outcome -> last_outcome := Some outcome)
      ~on_error:(fun error -> failure := Some (Format.asprintf "%a" Lwt_adapter.pp_error (Err.Error.kind error)))
  in
  let write text = Lwt.map ignore (Lwt_unix.write_string write_fd text 0 (String.length text)) in
  let () =
    Lwt_main.run
      (Lwt.bind
         (Lwt_list.iter_s
            (function
              | Scenario.Write text -> write text
              | Scenario.Short_write pieces -> Lwt_list.iter_s write pieces
              | Scenario.Backpressure_pause | Scenario.Backpressure_resume -> Lwt.return_unit
              | Scenario.Failure _ -> Lwt.return_unit
              | Scenario.Resize (columns, rows) -> Lwt.map ignore (Lwt_adapter.resize adapter ~columns ~rows)
              | Scenario.Coalesced_resize sizes ->
                  let columns, rows = List.nth sizes (List.length sizes - 1) in
                  Lwt.map ignore (Lwt_adapter.resize adapter ~columns ~rows)
              | Scenario.Eof -> Lwt_unix.close write_fd)
            scenario.events)
         (fun () -> reader))
  in
  match !failure with
  | Some message -> Error message
  | None -> ( match !last_outcome with Some outcome -> Ok (cells_of outcome) | None -> Error "no outcome observed")

let check (scenario : Scenario.scenario) (reference : Scenario.scenario) =
  let* actual = replay_via_lwt_adapter scenario in
  let* expected = Reference.run reference in
  match expected.last_outcome with
  | Some expected_outcome -> Ok (actual = cells_of expected_outcome)
  | None -> Error "reference scenario produced no outcome"

let%expect_test "the Lwt adapter reaches the same content as the reference driver: ordered ingress" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.ordered_ingress Scenario.ordered_ingress);
  [%expect {| true |}]

let%expect_test "the Lwt adapter reaches the same content as the reference driver: short writes" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.short_writes Scenario.short_writes_reference);
  [%expect {| true |}]

let%expect_test "the Lwt adapter reaches the same content as the reference driver: distinct-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.distinct_size_resize Scenario.distinct_size_resize);
  [%expect {| true |}]

let%expect_test "the Lwt adapter reaches the same content as the reference driver: equal-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.equal_size_resize Scenario.equal_size_resize);
  [%expect {| true |}]

let%expect_test "the Lwt adapter reaches the same content as the reference driver: coalesced resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.coalesced_resize Scenario.coalesced_resize);
  [%expect {| true |}]

let%expect_test "resize rejects a negative row or column count" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 2 in
    let adapter = Lwt_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    Result.map
      (fun _ -> "unexpectedly succeeded")
      (with_error_kind Lwt_adapter.pp_error (Lwt_main.run (Lwt_adapter.resize adapter ~columns:(-1) ~rows:2)))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-count(negative(-1)) |}]

let%expect_test "a read failure on a closed descriptor is reported, not raised" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 3 in
    let adapter = Lwt_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let read_fd, write_fd = Lwt_unix.pipe ~cloexec:true () in
    let () = Lwt_main.run (Lwt.bind (Lwt_unix.close read_fd) (fun () -> Lwt_unix.close write_fd)) in
    Result.map
      (fun _ -> "unexpectedly succeeded")
      (with_error_kind Lwt_adapter.pp_error (Lwt_main.run (Lwt_adapter.read_step adapter read_fd (Bytes.create 16))))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| read-failed(set_nonblock(): Bad file descriptor) |}]
