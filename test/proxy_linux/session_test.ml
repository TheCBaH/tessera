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
    Session.create ~argv:[| "ignored-by-fake-platform" |] ~env:[||] ~lineage_id ~policy ~terminal_in ~terminal_out
      ~observer_capacity:64 ~observer_start_position:Record.initial_sequence ~read_buffer_bytes:256
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
  (match Lwt_main.run (Session.on_master_readable session) with
  | Session.Application_ingest_failed error ->
      Format.printf "ingest failed as scripted: %a@." Tessera_lwt.Lwt_adapter.pp_error (Err.Error.kind error)
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
  (match Lwt_main.run (Session.on_master_readable session) with
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
  (match Lwt_main.run (Session.on_terminal_readable session) with
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

let%expect_test "a controller queue serializes browser input and suppresses physical input while leased" =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let session =
    start ~policy:(or_fail (policy ())) ~terminal_in:terminal_in_read ~terminal_out:(snd (Unix.pipe ())) ()
  in
  let pty = Session.Loop.pty (Session.loop session) in
  let start_cursor = Ring.cursor (Session.ring session) in
  Session.set_terminal_input_gate session (fun () -> false);
  ignore (Unix.write terminal_in_write (Bytes.of_string "physical") 0 8);
  (match Lwt_main.run (Session.on_terminal_readable session) with
  | Session.Terminal_input_ignored count -> Format.printf "physical input ignored: %d byte(s)@." count
  | _ -> Format.printf "unexpected physical-input event@.");
  Format.printf "physical reached child=%b@." (Option.is_some (Fake_platform.read_sent_to_child pty ~len:8));
  let payload = Bytes.of_string "web\000paste" in
  Format.printf "web enqueue=%b@." (Result.is_ok (Session.enqueue_web_input session payload));
  let input_ready, wake_event = Lwt.wait () in
  let stop, wake_stop = Lwt.wait () in
  let on_event input_event =
    match input_event with
    | Session.Terminal_input_relayed count when Lwt.is_sleeping input_ready -> Lwt.wakeup_later wake_event count
    | _ -> ()
  in
  let input_task = Session.run_web_input_loop session ~on_event ~stop in
  let received =
    Lwt.bind input_ready (fun count ->
        let received = Fake_platform.read_sent_to_child pty ~len:count in
        Lwt.wakeup_later wake_stop ();
        Lwt.map (fun () -> received) input_task)
  in
  (match Lwt_main.run received with
  | Some bytes -> Format.printf "web reached child verbatim=%b@." (String.equal bytes "web\000paste")
  | None -> Format.printf "web reached child verbatim=false@.");
  print_first_record (Session.ring session) start_cursor;
  [%expect
    {|
    physical input ignored: 8 byte(s)
    physical reached child=false
    web enqueue=true
    web reached child verbatim=true
    first record: traffic(#0, terminal-to-application, 9 byte(s)) |}]

(* Under the old [select]-based dispatch, the wake-up descriptor was always reported first when several descriptors
   were ready at once (proxy.md section 2 "Ordering against child output"). {!Session.run_master_loop},
   {!Session.run_terminal_loop}, and {!Session.Loop.wait_for_wakeup} are now three independent Lwt tasks with no
   ordering contract between them -- lwt.md's migration notes call this out explicitly as needing its own test rather
   than an assumption the old ordering still holds "because it did before". What this layer still guarantees: all
   three are delivered, regardless of which order the scheduler happens to service them in. *)
let%expect_test "a resize wake-up, application output, and terminal input pending at once are all delivered" =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let session =
    start ~policy:(or_fail (policy ())) ~terminal_in:terminal_in_read ~terminal_out:(snd (Unix.pipe ())) ()
  in
  let pty = Session.Loop.pty (Session.loop session) in
  Fake_platform.trigger_host_resize pty;
  Fake_platform.push_child_output pty "application";
  ignore (Unix.write terminal_in_write (Bytes.of_string "terminal") 0 8);
  let wakeup =
    Lwt.map
      (function Session.Resized (Session.Loop.Resized _) -> "wakeup" | _ -> "wakeup(unexpected)")
      (Lwt.bind (Session.Loop.wait_for_wakeup (Session.loop session)) (fun () -> Session.on_wakeup session))
  in
  let master =
    Lwt.map
      (function Session.Application_bytes _ -> "master" | _ -> "master(unexpected)")
      (Session.on_master_readable session)
  in
  let terminal_input =
    Lwt.map
      (function Session.Terminal_input_relayed _ -> "terminal-input" | _ -> "terminal-input(unexpected)")
      (Session.on_terminal_readable session)
  in
  let results = Lwt_main.run (Lwt.all [ wakeup; master; terminal_input ]) in
  Format.printf "%s@." (String.concat "; " (List.sort String.compare results));
  [%expect {| master; terminal-input; wakeup |}]

(* lwt-review.md P1: a bug fixed after the initial migration. [Session.run_relay] must end the session the instant
   *either* direction reaches EOF -- joining the two loops instead would wait for both, hanging forever whenever only
   one side ever reaches EOF (e.g. a child that exits while the real terminal stays open, an entirely ordinary case
   this test recreates: the child EOFs; nothing ever closes terminal input). *)
let%expect_test "the relay ends as soon as the child reaches EOF, without waiting for terminal input" =
  let terminal_in_read, _terminal_in_write_kept_open = Unix.pipe () in
  let session =
    start ~policy:(or_fail (policy ())) ~terminal_in:terminal_in_read ~terminal_out:(snd (Unix.pipe ())) ()
  in
  let pty = Session.Loop.pty (Session.loop session) in
  Fake_platform.close_child_output pty;
  let events = ref [] in
  Lwt_main.run (Session.run_relay session ~on_event:(fun event -> events := event :: !events));
  (match !events with
  | [ Session.Application_eof _ ] -> Format.printf "relay ended on the child's EOF alone@."
  | _ -> Format.printf "unexpected events@.");
  [%expect {| relay ended on the child's EOF alone |}]

let%expect_test "the relay ends as soon as terminal input reaches EOF, without waiting for the child" =
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let session =
    start ~policy:(or_fail (policy ())) ~terminal_in:terminal_in_read ~terminal_out:(snd (Unix.pipe ())) ()
  in
  Unix.close terminal_in_write;
  let events = ref [] in
  Lwt_main.run (Session.run_relay session ~on_event:(fun event -> events := event :: !events));
  (match !events with
  | [ Session.Terminal_input_eof ] -> Format.printf "relay ended on terminal input's EOF alone@."
  | _ -> Format.printf "unexpected events@.");
  [%expect {| relay ended on terminal input's EOF alone |}]
