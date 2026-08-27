module Foundation = Tessera_foundation

(* Design claim "State is immutable" / the Checkpoint boundary documented in terminal-impl.md: a
   [Tessera.session] value returned after a completed [ingest]/[finish] is a self-contained,
   restorable checkpoint. Restoring it and continuing is indistinguishable from having replayed its
   whole recorded prefix, and it supports more than one independent continuation without being
   disturbed by earlier ones. This is exercised through the public facade only, mirroring how a host
   adapter would retain and resume a session. *)

let replay_arbitrary =
  QCheck.make
    QCheck.Gen.(
      Generators.size_gen ~max_columns:Ingress.max_columns ~max_rows:Ingress.max_rows >>= fun size ->
      list_size (int_range 1 8) Ingress.input_gen >>= fun prefix ->
      Ingress.input_gen >>= fun probe -> return (size, prefix, probe))
    ~print:(fun (size, prefix, probe) ->
      let pp_input = function
        | Tessera.Bytes slice ->
            Printf.sprintf "bytes(%s)"
              (String.concat " "
                 (List.init
                    (Foundation.UInt.to_int (Foundation.Types.slice_len slice))
                    (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get (Foundation.Types.slice_bytes slice) i)))))
        | Tessera.Out_of_band (Tessera.Resize size) ->
            Printf.sprintf "resize(%dx%d)"
              (Foundation.UInt.to_int (Foundation.Types.Size.columns size))
              (Foundation.UInt.to_int (Foundation.Types.Size.rows size))
      in
      Printf.sprintf "size=%dx%d prefix=[%s] probe=%s"
        (Foundation.UInt.to_int (Foundation.Types.Size.columns size))
        (Foundation.UInt.to_int (Foundation.Types.Size.rows size))
        (String.concat "; " (List.map pp_input prefix))
        (pp_input probe))

let last outcomes = List.nth outcomes (List.length outcomes - 1)

let checkpoint_replay_is_deterministic =
  QCheck.Test.make ~count:200 ~name:"a retained session replays identically to re-running its recorded prefix"
    replay_arbitrary (fun (size, prefix, probe) ->
      let lineage_id = Generators.lineage_of_int 30 in
      match (Ingress.run_sequence ~lineage_id ~size prefix, Ingress.run_sequence ~lineage_id ~size prefix) with
      | Ok outcomes, Ok replayed_outcomes -> (
          let checkpoint = Tessera.session (last outcomes) in
          let replayed = Tessera.session (last replayed_outcomes) in
          Format.asprintf "%a" Tessera.pp_session checkpoint = Format.asprintf "%a" Tessera.pp_session replayed
          &&
          match (Tessera.ingest checkpoint probe, Tessera.ingest replayed probe) with
          | Ok from_checkpoint, Ok from_replay ->
              Format.asprintf "%a" Tessera.pp_outcome from_checkpoint
              = Format.asprintf "%a" Tessera.pp_outcome from_replay
          | Error _, _ | _, Error _ -> QCheck.Test.fail_report "session ingest reported an error for the probe input")
      | Error _, _ | _, Error _ -> QCheck.Test.fail_report "session ingest reported an error for generated input")

let branch_arbitrary =
  QCheck.make
    QCheck.Gen.(
      Generators.size_gen ~max_columns:Ingress.max_columns ~max_rows:Ingress.max_rows >>= fun size ->
      list_size (int_range 0 6) Ingress.input_gen >>= fun prefix ->
      Ingress.input_gen >>= fun probe_a ->
      Ingress.input_gen >>= fun probe_b -> return (size, prefix, probe_a, probe_b))
    ~print:(fun (_, prefix, _, _) -> Printf.sprintf "prefix_len=%d" (List.length prefix))

let checkpoint_supports_independent_branches =
  QCheck.Test.make ~count:200 ~name:"a retained checkpoint supports multiple independent continuations" branch_arbitrary
    (fun (size, prefix, probe_a, probe_b) ->
      let lineage_id = Generators.lineage_of_int 31 in
      match Ingress.run_sequence ~lineage_id ~size prefix with
      | Error _ -> QCheck.Test.fail_report "session ingest reported an error for generated prefix"
      | Ok outcomes ->
          let checkpoint =
            match outcomes with
            | [] -> Tessera.initial ~lineage_id ~policy:Generators.default_policy ~size
            | _ -> Tessera.session (last outcomes)
          in
          let render probe =
            match Tessera.ingest checkpoint probe with
            | Ok outcome -> Format.asprintf "%a" Tessera.pp_outcome outcome
            | Error _ -> QCheck.Test.fail_report "session ingest reported an error for a probe input"
          in
          let first_before = render probe_a in
          ignore (Tessera.ingest checkpoint probe_b);
          let first_after = render probe_a in
          first_before = first_after)

(* Design claim: [Tessera.Checkpoint] is a genuine serialisation boundary, not merely an in-memory handle. Encoding
   a session to bytes and decoding it back must be indistinguishable, by future behaviour, from having kept the
   original [Tessera.session] value -- for a session reached by an arbitrary generated prefix, and for the
   just-initialised session with no ingress at all. *)
let serialized_round_trip_matches_original session probe =
  match Tessera.ingest session probe with
  | Error _ -> QCheck.Test.fail_report "session ingest reported an error for the probe input"
  | Ok live_outcome -> (
      let checkpoint = Tessera.Checkpoint.of_session session in
      let bytes = Tessera.Checkpoint.to_bytes checkpoint in
      match Tessera.Checkpoint.to_session (Tessera.Checkpoint.of_bytes bytes) with
      | Error _ -> QCheck.Test.fail_report "checkpoint restore reported an error for validly encoded bytes"
      | Ok restored -> (
          match Tessera.ingest restored probe with
          | Error _ -> QCheck.Test.fail_report "restored session ingest reported an error for the probe input"
          | Ok restored_outcome ->
              Format.asprintf "%a" Tessera.pp_outcome live_outcome
              = Format.asprintf "%a" Tessera.pp_outcome restored_outcome))

let checkpoint_round_trip_after_prefix =
  QCheck.Test.make ~count:200 ~name:"encoding and decoding a checkpoint replays identically to the original session"
    replay_arbitrary (fun (size, prefix, probe) ->
      let lineage_id = Generators.lineage_of_int 32 in
      match Ingress.run_sequence ~lineage_id ~size prefix with
      | Error _ -> QCheck.Test.fail_report "session ingest reported an error for generated prefix"
      | Ok outcomes ->
          let session =
            match outcomes with
            | [] -> Tessera.initial ~lineage_id ~policy:Generators.default_policy ~size
            | _ -> Tessera.session (last outcomes)
          in
          serialized_round_trip_matches_original session probe)

let checkpoint_round_trip_from_initial =
  QCheck.Test.make ~count:100 ~name:"encoding and decoding a just-initialised session replays identically"
    (QCheck.make
       QCheck.Gen.(
         Generators.size_gen ~max_columns:Ingress.max_columns ~max_rows:Ingress.max_rows >>= fun size ->
         Ingress.input_gen >>= fun probe -> return (size, probe)))
    (fun (size, probe) ->
      let lineage_id = Generators.lineage_of_int 33 in
      let session = Tessera.initial ~lineage_id ~policy:Generators.default_policy ~size in
      serialized_round_trip_matches_original session probe)

let tests =
  [
    checkpoint_replay_is_deterministic;
    checkpoint_supports_independent_branches;
    checkpoint_round_trip_after_prefix;
    checkpoint_round_trip_from_initial;
  ]
