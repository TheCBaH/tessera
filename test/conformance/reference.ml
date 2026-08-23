(* The reference driver: a minimal, synchronous adapter that serialises Scenario.host_event values
   into ordered Tessera.ingest/finish calls. It is "the" conforming implementation this milestone
   can check the fixture against before any real scheduler adapter exists; a future adapter's own
   driver is expected to be compared against the same fixture. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
open Tessera_test_support.Support

type step = { label : string; summary : (string, string) result; outcome : Tessera.outcome option }
type run = { steps : step list; last_outcome : Tessera.outcome option }

let pp_patch_size ppf patch =
  match Tessera.Patch.size patch with
  | Tessera.Patch.Keep -> Format.pp_print_string ppf "keep"
  | Tessera.Patch.Set size -> Foundation.Types.Size.pp ppf size

let describe_outcome outcome =
  let patch = Tessera.outcome_patch outcome in
  Format.asprintf "%a; generation %a->%a; size=%a" Model.Effect.Item_sequence.pp (Tessera.outcome_items outcome)
    Foundation.Generation.pp (Tessera.Patch.before_generation patch) Foundation.Generation.pp
    (Tessera.Patch.after_generation patch) pp_patch_size patch

let ingest_bytes session text =
  let* chunk = slice text in
  with_error_kind Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes chunk))

let ingest_resize session columns rows =
  let* resized = size columns rows in
  with_error_kind Tessera.Session.pp_error (Tessera.ingest session (Tessera.Out_of_band (Tessera.Resize resized)))

let ingest_finish session = with_error_kind Tessera.Session.pp_error (Tessera.finish session)

let run (scenario : Scenario.scenario) =
  let* policy = policy () and* initial_size = size scenario.columns scenario.rows and* lineage_id = uint 1 in
  let session =
    ref (Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size)
  in
  let last_outcome = ref None in
  let stopped = ref false in
  let record label result =
    match result with
    | Ok outcome ->
        session := Tessera.session outcome;
        last_outcome := Some outcome;
        { label; summary = Ok (describe_outcome outcome); outcome = Some outcome }
    | Error message ->
        stopped := true;
        { label; summary = Error message; outcome = None }
  in
  let flow_control label = { label; summary = Ok "(flow control only, never becomes ingress)"; outcome = None } in
  let short_write pieces =
    let rec loop = function
      | [] -> invalid_arg "Scenario.Short_write: pieces must be non-empty"
      | [ last ] -> record (Printf.sprintf "short-write(final piece %S)" last) (ingest_bytes !session last)
      | piece :: rest -> (
          match ingest_bytes !session piece with
          | Ok outcome ->
              session := Tessera.session outcome;
              last_outcome := Some outcome;
              loop rest
          | Error message ->
              stopped := true;
              { label = Printf.sprintf "short-write(piece %S)" piece; summary = Error message; outcome = None })
    in
    loop pieces
  in
  let steps =
    List.filter_map
      (fun event ->
        if !stopped then None
        else
          match event with
          | Scenario.Backpressure_pause -> Some (flow_control "backpressure-pause")
          | Scenario.Backpressure_resume -> Some (flow_control "backpressure-resume")
          | Scenario.Failure message ->
              stopped := true;
              Some
                {
                  label = Printf.sprintf "failure(%S)" message;
                  summary = Error ("adapter stopped: " ^ message);
                  outcome = None;
                }
          | Scenario.Eof -> Some (record "eof" (ingest_finish !session))
          | Scenario.Write text -> Some (record (Printf.sprintf "write(%S)" text) (ingest_bytes !session text))
          | Scenario.Short_write pieces -> Some (short_write pieces)
          | Scenario.Resize (columns, rows) ->
              Some (record (Printf.sprintf "resize(%dx%d)" columns rows) (ingest_resize !session columns rows))
          | Scenario.Coalesced_resize sizes ->
              let dropped = List.length sizes - 1 in
              let columns, rows = List.nth sizes dropped in
              Some
                (record
                   (Printf.sprintf "coalesced-resize(delivers=%dx%d, drops=%d earlier notification(s))" columns rows
                      dropped)
                   (ingest_resize !session columns rows)))
      scenario.events
  in
  Ok { steps; last_outcome = !last_outcome }

let pp_step ppf step =
  match step.summary with
  | Ok summary -> Format.fprintf ppf "%s: %s" step.label summary
  | Error message -> Format.fprintf ppf "%s: ERROR %s" step.label message
