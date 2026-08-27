(* Deterministic proxy contract tests.  This is deliberately a pipe/socketpair
   suite: it exercises the synchronous session handlers without a controlling
   terminal, a PTY, a scheduler, or a clock. *)
module Foundation = Tessera_foundation
open Tessera_test_support.Support
module Test_random = Tessera_test_support.Test_random
module Fake_platform = Tessera_test_proxy_linux_fake_platform.Fake_platform
module Session = Tessera_proxy_linux.Session.Make (Fake_platform)
module Ring = Tessera_proxy_observer.Ring
module Record = Tessera_proxy_observer.Record

let ( let* ) = Result.bind
let or_fail = function Ok value -> value | Error message -> failwith message

let winsize columns rows =
  let* columns = uint columns and* rows = uint rows in
  Ok (Tessera_proxy_platform.Winsize.make ~columns ~rows ~pixels:None)

let size columns rows = or_fail (Tessera_test_support.Support.size columns rows)

let hex bytes =
  let encoded = Buffer.create (2 * Bytes.length bytes) in
  Bytes.iter (fun byte -> Buffer.add_string encoded (Printf.sprintf "%02x" (Char.code byte))) bytes;
  Buffer.contents encoded

let escaped text = String.escaped text

let pp_cell ppf cell =
  match Tessera.Cell.contents cell with
  | Tessera.Cell.Empty -> Format.pp_print_string ppf "blank"
  | Tessera.Cell.Wide_continuation -> Format.pp_print_string ppf "wide-continuation"
  | Tessera.Cell.Glyph grapheme -> Format.fprintf ppf "glyph(%s)" (escaped (Tessera.Model.Unicode.utf8 grapheme))

let canonical_snapshot snapshot =
  let size = Tessera.Renderer.size snapshot in
  let cursor = Tessera.Renderer.cursor snapshot in
  let cells = Tessera.Renderer.cells snapshot in
  let rows = Foundation.UInt.to_int (Foundation.Types.Size.rows size) in
  let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns size) in
  let row row =
    List.init columns (fun column ->
        let coord = or_fail (coord column row) in
        Format.asprintf "%a" pp_cell (Tessera.Collection.Snapshot_cells.get cells coord))
    |> String.concat ", "
  in
  let screen = Format.asprintf "%a" Foundation.Types.pp_screen (Tessera.Renderer.active snapshot) in
  let cursor_column = Foundation.UInt.to_int (Foundation.Types.Column.to_uint cursor.position.column) in
  let cursor_row = Foundation.UInt.to_int (Foundation.Types.Row.to_uint cursor.position.row) in
  let title = match Tessera.Renderer.title snapshot with None -> "none" | Some title -> escaped title in
  String.concat "\n"
    ([
       Printf.sprintf "size: %dx%d" columns rows;
       Printf.sprintf "active: %s" screen;
       Printf.sprintf "cursor: %d,%d pending-wrap=%b" cursor_column cursor_row cursor.pending_wrap;
       Printf.sprintf "title: %s" title;
       Printf.sprintf "cursor-visible: %b" (Tessera.Renderer.cursor_visible snapshot);
       "cells:";
     ]
    @ List.init rows (fun index -> Printf.sprintf "  %02d: %s" index (row index)))

let pp_record ppf = function
  | Record.Traffic { sequence; direction; bytes } ->
      Format.fprintf ppf "traffic(#%a, %a, %s)" Record.pp_sequence sequence Foundation.Types.pp_direction direction
        (hex bytes)
  | Record.Resize { sequence; size; pixels } ->
      let pixels = match pixels with None -> "none" | Some pixels -> Format.asprintf "%a" Record.Pixels.pp pixels in
      Format.fprintf ppf "resize(#%a, %a, %s)" Record.pp_sequence sequence Foundation.Types.Size.pp size pixels
  | Record.Effect { sequence; item } ->
      Format.fprintf ppf "effect(#%a, %a)" Record.pp_sequence sequence Tessera.Effect.pp_observation item

let records_since ring cursor =
  let rec loop cursor records =
    match Ring.read ring cursor with
    | None -> List.rev records
    | Some (Ring.Record (record, cursor)) -> loop cursor (record :: records)
    | Some (Ring.Gap { skipped; _ }) -> failwith (Printf.sprintf "unexpected observer gap (%d records)" skipped)
  in
  loop cursor []

let record_text record = Format.asprintf "%a" pp_record record

let assert_observer_log ~expected ~actual =
  let expected = List.map record_text expected in
  let actual = List.map record_text actual in
  if not (List.equal String.equal expected actual) then
    failwith
      (Printf.sprintf "observer log mismatch\nexpected:\n%s\nactual:\n%s" (String.concat "\n" expected)
         (String.concat "\n" actual))

let rec read_available fd ~len =
  Unix.set_nonblock fd;
  let buffer = Bytes.create len in
  match Unix.read fd buffer 0 len with
  | 0 -> None
  | read -> Some (Bytes.sub buffer 0 read)
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> None
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_available fd ~len

let start ?(observer_capacity = 4096) ~policy ~terminal_in ~terminal_out () =
  Fake_platform.set_physical_winsize (or_fail (winsize 4 2));
  let lineage_id = Foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  match
    Session.create ~argv:[| "ignored-by-fake-platform" |] ~lineage_id ~policy ~terminal_in ~terminal_out
      ~observer_capacity ~observer_start_position:Tessera_proxy_observer.Record.initial_sequence ~read_buffer_bytes:256
  with
  | Ok session -> session
  | Error error -> failwith (Format.asprintf "%a" Session.Loop.pp_error error)

type event = Application_bytes of bytes | Terminal_input of bytes | Resize of int * int | Wakeup | Application_eof

let direct_ingest_result direct bytes = Tessera.ingest !direct (Tessera.Bytes (or_fail (slice (Bytes.to_string bytes))))

let direct_ingest direct bytes =
  match direct_ingest_result direct bytes with
  | Ok outcome ->
      direct := Tessera.session outcome;
      outcome
  | Error error ->
      failwith (Format.asprintf "direct ingest failed: %a" (Err.Error.pp_kind Tessera.Session.pp_error) error)

let direct_resize direct columns rows =
  match Tessera.ingest !direct (Tessera.Out_of_band (Tessera.Resize (size columns rows))) with
  | Ok outcome ->
      direct := Tessera.session outcome;
      outcome
  | Error error ->
      failwith (Format.asprintf "direct resize failed: %a" (Err.Error.pp_kind Tessera.Session.pp_error) error)

let assert_same_snapshot ~step proxy direct =
  let proxy = canonical_snapshot (Tessera.outcome_snapshot proxy) in
  let direct = canonical_snapshot (Tessera.outcome_snapshot direct) in
  if not (String.equal proxy direct) then
    failwith (Printf.sprintf "%s snapshot mismatch\nproxy:\n%s\ndirect:\n%s" step proxy direct)

let drive events =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let terminal_out_read, terminal_out_write = Unix.pipe () in
  let policy = or_fail (policy ()) in
  let session = start ~policy ~terminal_in:terminal_in_read ~terminal_out:terminal_out_write () in
  let direct =
    ref (Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint (or_fail (uint 1))) ~policy ~size:(size 4 2))
  in
  let ring = Session.ring session in
  let start_cursor = Ring.cursor ring in
  let expected_records = ref [] in
  let next_sequence = ref Record.initial_sequence in
  let expect_record make =
    expected_records := !expected_records @ [ make !next_sequence ];
    next_sequence := Record.next_sequence !next_sequence
  in
  let expect_effects outcome =
    Tessera.Effect.Item_sequence.fold_left
      (fun () item ->
        match item with
        | Tessera.Effect.Observation item -> expect_record (fun sequence -> Record.effect_observation ~sequence ~item)
        | Tessera.Effect.Update _ -> ())
      () (Tessera.outcome_items outcome)
  in
  let expect_resize outcome =
    let size =
      match Tessera.Patch.size (Tessera.outcome_patch outcome) with
      | Tessera.Patch.Set size -> size
      | Tessera.Patch.Keep -> failwith "a proxy resize outcome must set its size"
    in
    expect_record (fun sequence -> Record.resize ~sequence ~size ~pixels:None);
    expect_effects outcome
  in
  let pty = Session.Loop.pty (Session.loop session) in
  let latest = ref None in
  let set_latest ~step outcome direct_outcome =
    latest := Some outcome;
    assert_same_snapshot ~step outcome direct_outcome
  in
  List.iteri
    (fun index event ->
      let step = Printf.sprintf "event %d" index in
      match event with
      | Application_bytes bytes -> (
          Fake_platform.push_child_bytes pty bytes;
          expect_record (fun sequence ->
              Record.traffic ~sequence ~direction:Foundation.Types.Application_to_terminal ~bytes);
          (match (direct_ingest_result direct bytes, Session.on_master_readable session) with
          | Ok direct_outcome, Session.Application_bytes outcome ->
              direct := Tessera.session direct_outcome;
              expect_effects direct_outcome;
              set_latest ~step outcome direct_outcome
          | Error _, Session.Application_ingest_failed _ -> ()
          | Ok _, Session.Application_ingest_failed error ->
              failwith
                (Format.asprintf "%s unexpectedly failed: %a" step Tessera_unix.Unix_adapter.pp_error
                   (Err.Error.kind error))
          | Error error, Session.Application_bytes _ ->
              failwith
                (Format.asprintf "%s proxy unexpectedly accepted malformed bytes: %a" step
                   (Err.Error.pp_kind Tessera.Session.pp_error)
                   error)
          | _ -> failwith (step ^ " returned a non-application event"));
          match read_available terminal_out_read ~len:(Bytes.length bytes) with
          | Some relayed when Bytes.equal relayed bytes -> ()
          | Some relayed -> failwith (Printf.sprintf "%s application relay changed bytes: %s" step (hex relayed))
          | None -> failwith (step ^ " application relay missing"))
      | Terminal_input bytes -> (
          let written = Unix.write terminal_in_write bytes 0 (Bytes.length bytes) in
          if written <> Bytes.length bytes then failwith "short test pipe write";
          expect_record (fun sequence ->
              Record.traffic ~sequence ~direction:Foundation.Types.Terminal_to_application ~bytes);
          (match Session.on_terminal_readable session with
          | Session.Terminal_input_relayed count when count = Bytes.length bytes -> ()
          | _ -> failwith (step ^ " terminal input was not relayed"));
          match Fake_platform.read_sent_to_child pty ~len:(Bytes.length bytes) with
          | Some relayed when String.equal relayed (Bytes.to_string bytes) -> ()
          | Some relayed ->
              failwith (Printf.sprintf "%s terminal relay changed bytes: %s" step (hex (Bytes.of_string relayed)))
          | None -> failwith (step ^ " terminal relay missing"))
      | Resize (columns, rows) -> (
          Fake_platform.set_physical_winsize (or_fail (winsize columns rows));
          Fake_platform.trigger_host_resize pty;
          let direct_outcome = direct_resize direct columns rows in
          expect_resize direct_outcome;
          match Session.on_wakeup session with
          | Session.Resized (Session.Loop.Resized outcome) -> set_latest ~step outcome direct_outcome
          | _ -> failwith (step ^ " resize was not applied"))
      | Wakeup -> (
          (* A wakeup always re-queries and applies the physical geometry, including a same-size
             refresh.  Mirror that core ingress in the direct oracle rather than treating wakeup
             as a no-op; a same-size resize can intentionally reset renderer transient state. *)
          let raw =
            match Fake_platform.physical_winsize () with
            | Ok raw -> raw
            | Error _ -> failwith (step ^ " fake physical size was not configured")
          in
          let direct_outcome =
            direct_resize direct
              (Foundation.UInt.to_int (Tessera_proxy_platform.Winsize.columns raw))
              (Foundation.UInt.to_int (Tessera_proxy_platform.Winsize.rows raw))
          in
          expect_resize direct_outcome;
          match Session.on_wakeup session with
          | Session.Resized (Session.Loop.Resized outcome) -> set_latest ~step outcome direct_outcome
          | _ -> failwith (step ^ " wakeup was not applied"))
      | Application_eof -> (
          Fake_platform.close_child_output pty;
          match Session.on_master_readable session with
          | Session.Application_eof outcome ->
              let direct_outcome =
                match Tessera.finish !direct with
                | Ok outcome ->
                    direct := Tessera.session outcome;
                    outcome
                | Error error ->
                    failwith
                      (Format.asprintf "direct finish failed: %a" (Err.Error.pp_kind Tessera.Session.pp_error) error)
              in
              set_latest ~step outcome direct_outcome
          | _ -> failwith (step ^ " did not produce application EOF")))
    events;
  assert_observer_log ~expected:!expected_records ~actual:(records_since ring start_cursor);
  Unix.close terminal_in_write;
  Unix.close terminal_out_read;
  (session, !latest, Ring.cursor ring)

let%expect_test "scenario vocabulary preserves exact traffic and matches the direct logical renderer after every step" =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let terminal_out_read, terminal_out_write = Unix.pipe () in
  let policy = or_fail (policy ()) in
  let session = start ~policy ~terminal_in:terminal_in_read ~terminal_out:terminal_out_write () in
  let direct =
    ref (Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint (or_fail (uint 1))) ~policy ~size:(size 4 2))
  in
  let ring = Session.ring session in
  let start_cursor = Ring.cursor ring in
  let last_direct = ref None in
  let pty = Session.Loop.pty (Session.loop session) in
  let application bytes =
    Fake_platform.push_child_bytes pty bytes;
    let direct_outcome = direct_ingest direct bytes in
    last_direct := Some direct_outcome;
    match Session.on_master_readable session with
    | Session.Application_bytes outcome -> (
        assert_same_snapshot ~step:"application" outcome direct_outcome;
        match read_available terminal_out_read ~len:(Bytes.length bytes) with
        | Some relayed -> assert (Bytes.equal relayed bytes)
        | None -> assert false)
    | _ -> assert false
  in
  application (Bytes.of_string "A\027]2;proxy title\007");
  let terminal = Bytes.of_string "\000\027[A\255" in
  ignore (Unix.write terminal_in_write terminal 0 (Bytes.length terminal));
  (match Session.on_terminal_readable session with Session.Terminal_input_relayed _ -> () | _ -> assert false);
  (match Fake_platform.read_sent_to_child pty ~len:(Bytes.length terminal) with
  | Some text -> assert (String.equal text (Bytes.to_string terminal))
  | None -> assert false);
  Fake_platform.set_physical_winsize (or_fail (winsize 6 3));
  Fake_platform.trigger_host_resize pty;
  let direct_outcome = direct_resize direct 6 3 in
  last_direct := Some direct_outcome;
  (match Session.on_wakeup session with
  | Session.Resized (Session.Loop.Resized outcome) -> assert_same_snapshot ~step:"resize" outcome direct_outcome
  | _ -> assert false);
  application (Bytes.of_string "\231\149\140xy");
  List.iter (fun record -> Format.printf "%a@." pp_record record) (records_since ring start_cursor);
  (match !last_direct with
  | Some outcome -> Format.printf "%s@." (canonical_snapshot (Tessera.outcome_snapshot outcome))
  | None -> assert false);
  [%expect
    {|
    traffic(#0, application-to-terminal, 411b5d323b70726f7879207469746c6507)
    traffic(#1, terminal-to-application, 001b5b41ff)
    resize(#2, 6×3, none)
    effect(#3, resize(6×3))
    traffic(#4, application-to-terminal, e7958c7879)
    size: 6x3
    active: primary
    cursor: 4,0 pending-wrap=false
    title: proxy title
    cursor-visible: true
    cells:
      00: glyph(A), glyph(\231\149\140), wide-continuation, glyph(x), blank, blank
      01: blank, blank, blank, blank, blank, blank
      02: blank, blank, blank, blank, blank, blank |}]

let%expect_test "invalid UTF-8 is exact relay-only on the terminal-to-application path" =
  let _session, _latest, _cursor =
    drive
      [ Application_bytes (Bytes.of_string "ok"); Terminal_input (Bytes.of_string "\000\255\027[Z"); Application_eof ]
  in
  Format.printf "terminal bytes bypassed decoding and the application EOF completed@.";
  [%expect {| terminal bytes bypassed decoding and the application EOF completed |}]

let%expect_test "ingestion failure is typed and cannot suppress an already-relayed application chunk" =
  let terminal_out_read, terminal_out_write = Unix.pipe () in
  let terminal_in_read, _terminal_in_write = Unix.pipe () in
  let max_columns = or_fail (uint 80) in
  let max_control_bytes = or_fail (uint 1024) in
  let max_csi_params = or_fail (uint 16) in
  let max_diagnostics = or_fail (uint 16) in
  let max_rows = or_fail (uint 24) in
  let max_slice_bytes = or_fail (uint 2) in
  let max_snapshot_cells = or_fail (uint 1920) in
  let limits =
    or_fail
      (with_error_kind Foundation.Limits.pp_error
         (Foundation.Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows
            ~max_slice_bytes ~max_snapshot_cells))
  in
  let session =
    start
      ~policy:(Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)
      ~terminal_in:terminal_in_read ~terminal_out:terminal_out_write ()
  in
  let ring = Session.ring session in
  let start_cursor = Ring.cursor ring in
  let pty = Session.Loop.pty (Session.loop session) in
  let payload = Bytes.of_string "abc\000\027[A\255" in
  Fake_platform.push_child_bytes pty payload;
  (match Session.on_master_readable session with
  | Session.Application_ingest_failed error ->
      Format.printf "typed failure: %a@." Tessera_unix.Unix_adapter.pp_error (Err.Error.kind error)
  | _ -> assert false);
  (match read_available terminal_out_read ~len:(Bytes.length payload) with
  | Some relayed -> Format.printf "relay hex: %s@." (hex relayed)
  | None -> assert false);
  List.iter (fun record -> Format.printf "%a@." pp_record record) (records_since ring start_cursor);
  [%expect
    {|
    typed failure: session(decode(invalid slice))
    relay hex: 616263001b5b41ff
    traffic(#0, application-to-terminal, 616263001b5b41ff) |}]

let%expect_test "a fixed-seed generated corpus remains a direct-renderer equivalence property without random goldens" =
  let random = Test_random.State.make [| 0x54455341 |] in
  let fragments = [| "a"; "\027[2C"; "界"; "\027[H"; "Z"; "\027[2J"; "\027[?25l"; "\027[?25h" |] in
  let events =
    List.init 32 (fun _ ->
        Application_bytes (Bytes.of_string fragments.(Test_random.State.int random (Array.length fragments))))
  in
  let _session, latest, _cursor = drive events in
  (match latest with
  | Some outcome ->
      Format.printf "seeded corpus final projection:\n%s@." (canonical_snapshot (Tessera.outcome_snapshot outcome))
  | None -> assert false);
  [%expect
    {|
    seeded corpus final projection:
    size: 4x2
    active: primary
    cursor: 3,0 pending-wrap=false
    title: none
    cursor-visible: true
    cells:
      00: glyph(a), blank, blank, blank
      01: glyph(\231\149\140), wide-continuation, blank, blank |}]

(* This deterministic state machine is deliberately a property corpus rather than an expect
   golden: each seed exercises the entire proxy contract (both relay directions, resize/wakeup
   ordering, and direct-session equivalence) and reports a replayable scenario if it fails.  The
   small curated scenario above remains the readable golden; this catches interactions that would
   be impractical to enumerate. *)
let pp_event = function
  | Application_bytes bytes -> Printf.sprintf "application(%s)" (hex bytes)
  | Terminal_input bytes -> Printf.sprintf "terminal(%s)" (hex bytes)
  | Resize (columns, rows) -> Printf.sprintf "resize(%dx%d)" columns rows
  | Wakeup -> "wakeup"
  | Application_eof -> "application-eof"

let generated_events seed =
  let random = Test_random.State.make [| seed |] in
  let application_fragments =
    [|
      "a";
      "\027[2C";
      "\231\149\140";
      "\027[H";
      "\027[2J";
      "\027[?25l";
      "\027[?25h";
      "\027]2;generated title\007";
      "\027[31mR\027[0m";
      "\027[2@";
      "\027[1P";
      "\027[2K";
      "\027[1L";
      "\027[1M";
      "\n";
      "\027[?1049h";
      "\027[?1049l";
      "\255";
    |]
  in
  let terminal_fragments = [| "\000"; "\027[A"; "\255"; "x"; "\027[Z" |] in
  List.init 128 (fun _ ->
      match Test_random.State.int random 7 with
      | 0 | 1 | 2 ->
          Application_bytes
            (Bytes.of_string application_fragments.(Test_random.State.int random (Array.length application_fragments)))
      | 3 | 4 ->
          Terminal_input
            (Bytes.of_string terminal_fragments.(Test_random.State.int random (Array.length terminal_fragments)))
      | 5 -> Resize (1 + Test_random.State.int random 12, 1 + Test_random.State.int random 6)
      | _ -> Wakeup)
  @ [ Application_eof ]

let rec remove_at index = function
  | [] -> []
  | _ :: rest when index = 0 -> rest
  | item :: rest -> item :: remove_at (index - 1) rest

(* A failing sequence is reduced before it is reported.  The trailing EOF is retained so every
   candidate still exercises the proxy's normal lifetime.  This greedy delta pass is deliberately
   local and deterministic: the printed scenario can be copied into a curated regression without
   depending on a QCheck shrinker or an OCaml-version-specific random implementation. *)
let minimize_failure events =
  let fails candidate =
    try
      ignore (drive candidate);
      false
    with Failure _ -> true
  in
  let rec loop candidate index =
    if index >= List.length candidate - 1 then candidate
    else
      let reduced = remove_at index candidate in
      if fails reduced then loop reduced index else loop candidate (index + 1)
  in
  loop events 0

let serialise_events events = String.concat "; " (List.map pp_event events)

let%expect_test "generated proxy event sequences preserve relay and direct-session equivalence" =
  let seeds = Array.init 32 (fun index -> 0x50524f58 + index) in
  Array.iter
    (fun seed ->
      let events = generated_events seed in
      try ignore (drive events)
      with Failure message ->
        let reduced = minimize_failure events in
        failwith
          (Printf.sprintf "generated proxy contract failed (seed=%08x; scenario=[%s]; minimized=[%s]): %s" seed
             (serialise_events events) (serialise_events reduced) message))
    seeds;
  Format.printf "generated proxy contract passed for %d replayable seeds@." (Array.length seeds);
  [%expect {| generated proxy contract passed for 32 replayable seeds |}]
