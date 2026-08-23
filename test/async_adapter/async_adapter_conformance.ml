(* Replays test/conformance's reusable fixture against the real Async scheduler adapter reading
   from an OS pipe, mirroring test/unix_adapter and test/lwt_adapter. Scenario.Backpressure_pause/
   resume carry nothing to deliver on a real descriptor (they are pure flow control even for a real
   adapter) and Scenario.Failure isn't meaningfully reproducible on a plain pipe, so those two
   scenarios are exercised directly below instead of through this generic replay. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
module Scenario = Tessera_test_conformance.Scenario
module Reference = Tessera_test_conformance.Reference
module Async_adapter = Tessera_async.Async_adapter
open Tessera_test_support.Support

let cells_of outcome =
  Format.asprintf "%a" Model.Collection.Snapshot_cells.pp (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome))

let reader_of_read_end read_fd =
  let fd = Async.Fd.create Async.Fd.Kind.Fifo read_fd (Core.Info.of_string "tessera-async-adapter-test") in
  Async.Reader.create fd

let write text write_fd = ignore (Unix.write_substring write_fd text 0 (String.length text))

let rec run_events adapter write_fd events =
  match events with
  | [] -> Async.Deferred.return ()
  | Scenario.Resize (columns, rows) :: rest ->
      Async.Deferred.bind (Async_adapter.resize adapter ~columns ~rows) ~f:(fun _ -> run_events adapter write_fd rest)
  | Scenario.Coalesced_resize sizes :: rest ->
      let columns, rows = List.nth sizes (List.length sizes - 1) in
      Async.Deferred.bind (Async_adapter.resize adapter ~columns ~rows) ~f:(fun _ -> run_events adapter write_fd rest)
  | Scenario.Write text :: rest ->
      write text write_fd;
      run_events adapter write_fd rest
  | Scenario.Short_write pieces :: rest ->
      List.iter (fun text -> write text write_fd) pieces;
      run_events adapter write_fd rest
  | (Scenario.Backpressure_pause | Scenario.Backpressure_resume | Scenario.Failure _) :: rest ->
      run_events adapter write_fd rest
  | Scenario.Eof :: rest ->
      Unix.close write_fd;
      run_events adapter write_fd rest

let replay_via_async_adapter (scenario : Scenario.scenario) =
  let* policy = policy () and* initial_size = size scenario.columns scenario.rows and* lineage_id = uint 1 in
  let adapter =
    Async_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size
  in
  let read_fd, write_fd = Unix.pipe ~cloexec:true () in
  let last_outcome = ref None in
  let failure = ref None in
  Async.Thread_safe.block_on_async_exn (fun () ->
      let reader = reader_of_read_end read_fd in
      let reader_loop =
        Async_adapter.run adapter reader ~read_buffer_bytes:4096
          ~on_outcome:(fun outcome -> last_outcome := Some outcome)
          ~on_error:(fun error -> failure := Some (Format.asprintf "%a" Async_adapter.pp_error (Err.Error.kind error)))
      in
      Async.Deferred.bind (run_events adapter write_fd scenario.events) ~f:(fun () -> reader_loop));
  match !failure with
  | Some message -> Error message
  | None -> ( match !last_outcome with Some outcome -> Ok (cells_of outcome) | None -> Error "no outcome observed")

let check (scenario : Scenario.scenario) (reference : Scenario.scenario) =
  let* actual = replay_via_async_adapter scenario in
  let* expected = Reference.run reference in
  match expected.last_outcome with
  | Some expected_outcome -> Ok (actual = cells_of expected_outcome)
  | None -> Error "reference scenario produced no outcome"

let%expect_test "the Async adapter reaches the same content as the reference driver: ordered ingress" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.ordered_ingress Scenario.ordered_ingress);
  [%expect {| true |}]

let%expect_test "the Async adapter reaches the same content as the reference driver: short writes" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.short_writes Scenario.short_writes_reference);
  [%expect {| true |}]

let%expect_test "the Async adapter reaches the same content as the reference driver: distinct-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.distinct_size_resize Scenario.distinct_size_resize);
  [%expect {| true |}]

let%expect_test "the Async adapter reaches the same content as the reference driver: equal-size resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.equal_size_resize Scenario.equal_size_resize);
  [%expect {| true |}]

let%expect_test "the Async adapter reaches the same content as the reference driver: coalesced resize" =
  Format.printf "%a@." (pp_result Fmt.bool) (check Scenario.coalesced_resize Scenario.coalesced_resize);
  [%expect {| true |}]

let%expect_test "resize rejects a negative row or column count" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 2 in
    let adapter = Async_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    Result.map
      (fun _ -> "unexpectedly succeeded")
      (with_error_kind Async_adapter.pp_error
         (Async.Thread_safe.block_on_async_exn (fun () -> Async_adapter.resize adapter ~columns:(-1) ~rows:2)))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-count(negative(-1)) |}]

(* The Read_failed payload embeds Async's Reader.t sexp, which carries the raw OS file-descriptor
   number -- not deterministic across runs -- so this checks the error's shape (a caught
   Read_failed, not a raised exception) rather than its exact rendered text. *)
let is_read_failed = function `Read_failed _ -> true | _ -> false

let%expect_test "a read failure on a closed descriptor is reported, not raised" =
  let result =
    let* policy = policy () and* size = size 4 2 and* lineage_id = uint 3 in
    let adapter = Async_adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let read_fd, write_fd = Unix.pipe ~cloexec:true () in
    Unix.close read_fd;
    Unix.close write_fd;
    let outcome =
      Async.Thread_safe.block_on_async_exn (fun () ->
          Async_adapter.read_step adapter (reader_of_read_end read_fd) (Bytes.create 16))
    in
    Ok (match outcome with Ok _ -> false | Error error -> is_read_failed (Err.Error.kind error))
  in
  Format.printf "%a@." (pp_result Fmt.bool) result;
  [%expect {| true |}]
