(* Layer 3 (proxy.md "Testing"): Ring/observer tests, pure and scripted -- no descriptor or signal
   involved. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
open Tessera_test_support.Support
module Record = Tessera_proxy_observer.Record
module Ring = Tessera_proxy_observer.Ring

let ( let* ) = Result.bind
let or_fail = function Ok value -> value | Error message -> failwith message
let publish ring make = Ring.publish ring (make (Ring.next_sequence ring))

let%expect_test "publishing past capacity overwrites the oldest record; read reports the exact drop count" =
  let ring = Ring.create ~capacity:4 ~start_position:Record.initial_sequence in
  let start = Ring.cursor ring in
  for i = 1 to 10 do
    publish ring (fun sequence ->
        Record.traffic ~sequence ~direction:Foundation.Types.Terminal_to_application
          ~bytes:(Bytes.of_string (string_of_int i)))
  done;
  (match Ring.read ring start with
  | Some (Ring.Gap { skipped; resume }) -> (
      Format.printf "gap skipped=%d@." skipped;
      match Ring.read ring resume with
      | Some (Ring.Record (record, _)) -> Format.printf "first retained: %a@." Record.pp record
      | _ -> Format.printf "expected the first retained record@.")
  | _ -> Format.printf "expected a gap@.");
  Format.printf "caught up: %b@." (Ring.read ring (Ring.cursor ring) = None);
  [%expect
    {|
    gap skipped=6
    first retained: traffic(#6, terminal-to-application, 1 byte(s))
    caught up: true |}]

(* A scripted interleaved traffic/resize/effect stream, driven through a real Tessera session so
   {!Ring.authoritative_snapshot} has a real outcome to resync from. *)
let scripted_records () =
  let* policy = policy () and* initial_size = size 4 2 and* lineage_id_uint = uint 1 in
  let lineage_id = Foundation.Lineage_id.of_uint lineage_id_uint in
  let session = ref (Tessera.initial ~lineage_id ~policy ~size:initial_size) in
  let pending = ref [] in
  let push make = pending := make :: !pending in
  let record_effects outcome =
    Model.Effect.Item_sequence.fold_left
      (fun () item ->
        match item with
        | Model.Effect.Observation item -> push (fun sequence -> Record.effect_observation ~sequence ~item)
        | Model.Effect.Update _ -> ())
      () (Tessera.outcome_items outcome)
  in
  let write text =
    let* chunk = slice text in
    let* outcome = with_error_kind Tessera.Session.pp_error (Tessera.ingest !session (Tessera.Bytes chunk)) in
    session := Tessera.session outcome;
    push (fun sequence ->
        Record.traffic ~sequence ~direction:Foundation.Types.Application_to_terminal ~bytes:(Bytes.of_string text));
    record_effects outcome;
    Ok outcome
  in
  let resize columns rows =
    let* resized = size columns rows in
    let* outcome =
      with_error_kind Tessera.Session.pp_error (Tessera.ingest !session (Tessera.Out_of_band (Tessera.Resize resized)))
    in
    session := Tessera.session outcome;
    push (fun sequence -> Record.resize ~sequence ~size:resized ~pixels:None);
    record_effects outcome;
    Ok outcome
  in
  let* _ = write "AB" in
  let* _ = resize 6 2 in
  let* _ = write "CDEF" in
  let* _ = resize 6 4 in
  let* _ = write "GH" in
  let* final = with_error_kind Tessera.Session.pp_error (Tessera.finish !session) in
  Ok (List.rev !pending, final)

let snapshot_of outcome = Tessera.Renderer.cells (Tessera.outcome_snapshot outcome)

let%expect_test
    "a full-history reader and a gapped-then-resynced reader converge on the same final snapshot; sequence order \
     across all three record kinds matches publish order" =
  let pending, final_outcome = or_fail (scripted_records ()) in
  let total = List.length pending in
  Format.printf "records total: %d@." total;
  let full = Ring.create ~capacity:(total + 1) ~start_position:Record.initial_sequence in
  let full_start = Ring.cursor full in
  let gappy = Ring.create ~capacity:3 ~start_position:Record.initial_sequence in
  let gappy_start = Ring.cursor gappy in
  List.iter (publish full) pending;
  List.iter (publish gappy) pending;
  let rec drain ring cursor acc =
    match Ring.read ring cursor with
    | None -> List.rev acc
    | Some (Ring.Record (record, cursor)) -> drain ring cursor (record :: acc)
    | Some (Ring.Gap { resume; _ }) -> drain ring resume acc
  in
  let full_records = drain full full_start [] in
  Format.printf "full reader saw %d record(s) with no gap, in order:@." (List.length full_records);
  List.iter (fun record -> Format.printf "  %a@." Record.pp record) full_records;
  (match Ring.read gappy gappy_start with
  | Some (Ring.Gap { skipped; _ }) -> Format.printf "gappy reader hit a gap of %d record(s) first@." skipped
  | _ -> Format.printf "expected the gappy reader to observe a gap@.");
  let resync_cells, resync_cursor = Ring.authoritative_snapshot gappy final_outcome in
  let ground_truth_cells = snapshot_of final_outcome in
  Format.printf "resynced snapshot matches the ground-truth outcome snapshot: %b@."
    (Format.asprintf "%a" Model.Collection.Snapshot_cells.pp resync_cells
    = Format.asprintf "%a" Model.Collection.Snapshot_cells.pp ground_truth_cells);
  Format.printf "resync cursor is caught up: %b@." (Ring.read gappy resync_cursor = None);
  [%expect
    {|
    records total: 7
    full reader saw 7 record(s) with no gap, in order:
      traffic(#0, application-to-terminal, 2 byte(s))
      resize(#1, 6×2)
      effect(#2, resize(6×2))
      traffic(#3, application-to-terminal, 4 byte(s))
      resize(#4, 6×4)
      effect(#5, resize(6×4))
      traffic(#6, application-to-terminal, 2 byte(s))
    gappy reader hit a gap of 4 record(s) first
    resynced snapshot matches the ground-truth outcome snapshot: true
    resync cursor is caught up: true |}]
