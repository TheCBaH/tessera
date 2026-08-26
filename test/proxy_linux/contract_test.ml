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

let rec read_available fd ~len =
  Unix.set_nonblock fd;
  let buffer = Bytes.create len in
  match Unix.read fd buffer 0 len with
  | 0 -> None
  | read -> Some (Bytes.sub buffer 0 read)
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> None
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_available fd ~len

let start ~policy ~terminal_in ~terminal_out () =
  Fake_platform.set_physical_winsize (or_fail (winsize 4 2));
  let lineage_id = Foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  match
    Session.create ~argv:[| "ignored-by-fake-platform" |] ~lineage_id ~policy ~terminal_in ~terminal_out
      ~observer_capacity:64 ~read_buffer_bytes:256
  with
  | Ok session -> session
  | Error error -> failwith (Format.asprintf "%a" Session.Loop.pp_error error)

type event = Application_bytes of bytes | Terminal_input of bytes | Resize of int * int | Wakeup | Application_eof

let direct_ingest direct bytes =
  match Tessera.ingest !direct (Tessera.Bytes (or_fail (slice (Bytes.to_string bytes)))) with
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
  let cursor = ref (Ring.cursor ring) in
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
          let direct_outcome = direct_ingest direct bytes in
          (match Session.on_master_readable session with
          | Session.Application_bytes outcome -> set_latest ~step outcome direct_outcome
          | Session.Application_ingest_failed error ->
              failwith
                (Format.asprintf "%s unexpectedly failed: %a" step Tessera_unix.Unix_adapter.pp_error
                   (Err.Error.kind error))
          | _ -> failwith (step ^ " returned a non-application event"));
          match read_available terminal_out_read ~len:(Bytes.length bytes) with
          | Some relayed when Bytes.equal relayed bytes -> ()
          | Some relayed -> failwith (Printf.sprintf "%s application relay changed bytes: %s" step (hex relayed))
          | None -> failwith (step ^ " application relay missing"))
      | Terminal_input bytes -> (
          let written = Unix.write terminal_in_write bytes 0 (Bytes.length bytes) in
          if written <> Bytes.length bytes then failwith "short test pipe write";
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
          match Session.on_wakeup session with
          | Session.Resized (Session.Loop.Resized outcome) -> set_latest ~step outcome direct_outcome
          | _ -> failwith (step ^ " resize was not applied"))
      | Wakeup -> ignore (Session.on_wakeup session)
      | Application_eof ->
          Fake_platform.close_child_output pty;
          (match Session.on_master_readable session with
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
          | _ -> failwith (step ^ " did not produce application EOF"));
          cursor := Ring.cursor ring)
    events;
  Unix.close terminal_in_write;
  Unix.close terminal_out_read;
  (session, !latest, !cursor)

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
