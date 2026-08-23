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
    ~print:(fun (_, prefix, _) -> Printf.sprintf "prefix_len=%d" (List.length prefix))

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

let tests = [ checkpoint_replay_is_deterministic; checkpoint_supports_independent_branches ]
