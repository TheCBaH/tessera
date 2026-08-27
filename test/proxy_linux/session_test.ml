(* Layer 2 (proxy.md "Testing"): what the proxy adds on top of test/conformance's already-validated
   ingress ordering/content -- verbatim relay to the real terminal happening independently of ingest
   succeeding or failing. No real PTY, no real signal: Fake_platform's master_fd is a socketpair, so
   both relay directions are directly observable from the test side. *)
module Foundation = Tessera_foundation
open Tessera_test_support.Support
module Fake_platform = Tessera_test_proxy_linux_fake_platform.Fake_platform
module Session = Tessera_proxy_linux.Session.Make (Fake_platform)
module Ring = Tessera_proxy_observer.Ring
module Record = Tessera_proxy_observer.Record

let ( let* ) = Result.bind
let or_fail = function Ok value -> value | Error message -> failwith message

let winsize columns rows =
  let* columns = uint columns and* rows = uint rows in
  Ok (Tessera_proxy_platform.Winsize.make ~columns ~rows ~pixels:None)

(* A policy whose [max_slice_bytes] is small enough that a multi-byte chunk fails to decode -- the
   scripted ingest failure this layer's test needs, per proxy.md's own "Decoding never delays or alters
   the bytes actually written to the terminal" requirement. *)
let tiny_slice_policy () =
  let* max_columns = uint 80
  and* max_control_bytes = uint 1024
  and* max_csi_params = uint 16
  and* max_diagnostics = uint 16
  and* max_rows = uint 24
  and* max_slice_bytes = uint 2
  and* max_snapshot_cells = uint 1920 in
  let* limits =
    with_error_kind Foundation.Limits.pp_error
      (Foundation.Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows
         ~max_slice_bytes ~max_snapshot_cells)
  in
  Ok (Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)

let rec read_available fd ~len =
  Unix.set_nonblock fd;
  let buffer = Bytes.create len in
  match Unix.read fd buffer 0 len with
  | 0 -> None
  | read -> Some (Bytes.sub_string buffer 0 read)
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

let print_first_record ring cursor =
  match Ring.read ring cursor with
  | Some (Ring.Record (record, _)) -> Format.printf "first record: %a@." Record.pp record
  | Some (Ring.Gap _) -> Format.printf "unexpected gap@."
  | None -> Format.printf "expected a record@."

let%expect_test "application-to-terminal bytes are relayed verbatim even when a scripted ingest failure stops decoding"
    =
  let terminal_out_read, terminal_out_write = Unix.pipe () in
  let policy = or_fail (tiny_slice_policy ()) in
  let session = start ~policy ~terminal_in:(fst (Unix.pipe ())) ~terminal_out:terminal_out_write () in
  let ring = Session.ring session in
  let start_cursor = Ring.cursor ring in
  let pty = Session.Loop.pty (Session.loop session) in
  let payload = "this exceeds the tiny max_slice_bytes policy limit" in
  Fake_platform.push_child_output pty payload;
  (match Session.on_master_readable session with
  | Session.Application_ingest_failed error ->
      Format.printf "ingest failed as scripted: %a@." Tessera_unix.Unix_adapter.pp_error (Err.Error.kind error)
  | Session.Application_bytes _ -> Format.printf "unexpectedly succeeded@."
  | _ -> Format.printf "unexpected event@.");
  (match read_available terminal_out_read ~len:(String.length payload) with
  | Some relayed -> Format.printf "relayed verbatim despite ingest failure: %b@." (String.equal relayed payload)
  | None -> Format.printf "nothing was relayed@.");
  print_first_record ring start_cursor;
  [%expect
    {|
    ingest failed as scripted: session(decode(invalid slice))
    relayed verbatim despite ingest failure: true
    first record: traffic(#0, application-to-terminal, 50 byte(s)) |}]

let%expect_test "application-to-terminal bytes that decode successfully are relayed, published, and ingested" =
  let terminal_out_read, terminal_out_write = Unix.pipe () in
  let policy = or_fail (policy ()) in
  let session = start ~policy ~terminal_in:(fst (Unix.pipe ())) ~terminal_out:terminal_out_write () in
  let ring = Session.ring session in
  let start_cursor = Ring.cursor ring in
  let pty = Session.Loop.pty (Session.loop session) in
  Fake_platform.push_child_output pty "hi";
  (match Session.on_master_readable session with
  | Session.Application_bytes outcome ->
      Format.printf "ingested: %a@." Tessera_model.Effect.Item_sequence.pp (Tessera.outcome_items outcome)
  | _ -> Format.printf "unexpected event@.");
  (match read_available terminal_out_read ~len:2 with
  | Some relayed -> Format.printf "relayed verbatim: %s@." relayed
  | None -> Format.printf "nothing was relayed@.");
  print_first_record ring start_cursor;
  [%expect
    {|
    ingested: [update(print([<U+0068>]))]
    relayed verbatim: hi
    first record: traffic(#0, application-to-terminal, 2 byte(s)) |}]

let%expect_test "terminal-to-application bytes are relayed verbatim to the child and never ingested" =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let policy = or_fail (policy ()) in
  let session = start ~policy ~terminal_in:terminal_in_read ~terminal_out:(snd (Unix.pipe ())) () in
  let ring = Session.ring session in
  let start_cursor = Ring.cursor ring in
  let pty = Session.Loop.pty (Session.loop session) in
  let payload = "user keystrokes" in
  let written = Unix.write terminal_in_write (Bytes.of_string payload) 0 (String.length payload) in
  assert (written = String.length payload);
  (match Session.on_terminal_readable session with
  | Session.Terminal_input_relayed count -> Format.printf "relayed %d byte(s)@." count
  | _ -> Format.printf "unexpected event@.");
  (match Fake_platform.read_sent_to_child pty ~len:(String.length payload) with
  | Some received -> Format.printf "the child received it verbatim: %b@." (String.equal received payload)
  | None -> Format.printf "the child received nothing@.");
  print_first_record ring start_cursor;
  [%expect
    {|
    relayed 15 byte(s)
    the child received it verbatim: true
    first record: traffic(#0, terminal-to-application, 15 byte(s)) |}]

let%expect_test "wakeup readiness stays ahead of both application output and terminal input" =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let session =
    start ~policy:(or_fail (policy ())) ~terminal_in:terminal_in_read ~terminal_out:(snd (Unix.pipe ())) ()
  in
  let pty = Session.Loop.pty (Session.loop session) in
  Fake_platform.trigger_host_resize pty;
  Fake_platform.push_child_output pty "application";
  ignore (Unix.write terminal_in_write (Bytes.of_string "terminal") 0 8);
  let pp_ready ppf = function
    | Session.Wakeup -> Format.pp_print_string ppf "wakeup"
    | Session.Master -> Format.pp_print_string ppf "master"
    | Session.Terminal_input -> Format.pp_print_string ppf "terminal-input"
    | Session.Extra_read _ -> Format.pp_print_string ppf "extra-read"
    | Session.Extra_write _ -> Format.pp_print_string ppf "extra-write"
  in
  Format.printf "[%a]@."
    (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_ready)
    (Session.select session ~extra_read_fds:[] ~extra_write_fds:[] ~timeout:0.0);
  [%expect {| [wakeup; master; terminal-input] |}]
