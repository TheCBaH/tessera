(* Socket-level integration tests for milestones.md's "observable proxy service": connect, reconnect, a slow
   consumer, gap/resync, record ordering, and proof that observer activity never alters or blocks byte relay. *)
module Foundation = Tessera_foundation
open Tessera_test_support.Support
module Fake_platform = Tessera_test_proxy_linux_fake_platform.Fake_platform
module Session = Tessera_proxy_linux.Session.Make (Fake_platform)
module Observer_server = Tessera_proxy_linux.Observer_server
module Ring = Tessera_proxy_observer.Ring
module Record = Tessera_proxy_observer.Record
module Frame = Tessera_proxy_protocol.Frame

let ( let* ) = Result.bind
let or_fail = function Ok value -> value | Error message -> failwith message
let or_fail_err pp = function Ok value -> value | Error error -> failwith (Format.asprintf "%a" pp error)

let winsize columns rows =
  let* columns = uint columns and* rows = uint rows in
  Ok (Tessera_proxy_platform.Winsize.make ~columns ~rows ~pixels:None)

(* A path whose parent directory does not exist yet, so {!Observer_server.create}'s own [mkdir 0o700] is actually
   exercised by these tests rather than reusing the shared, non-private system temp directory. *)
let fresh_socket_path () =
  let directory = Filename.temp_file "tessera-proxy-observer-test" "" in
  Sys.remove directory;
  Filename.concat directory "observer.sock"

let make_outcome () =
  let policy = or_fail (policy ()) in
  let lineage_id = Foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  let session = Tessera.initial ~lineage_id ~policy ~size:(or_fail (Tessera_test_support.Support.size 4 2)) in
  or_fail_err
    (fun ppf error -> Tessera.Session.pp_error ppf (Err.Error.kind error))
    (Tessera.ingest session (Tessera.Bytes (or_fail (slice "hi"))))

(* Reads every frame currently available on [fd] (non-blocking; stops at [EAGAIN]) through a persistent {!Frame.reader}
   so a test can inspect exactly what a real client would have decoded. *)
let read_frames state fd =
  Unix.set_nonblock fd;
  let buffer = Bytes.create 4096 in
  let rec loop state acc =
    match Unix.read fd buffer 0 (Bytes.length buffer) with
    | 0 -> (state, List.rev acc)
    | len -> (
        match Frame.feed state buffer ~off:0 ~len with
        | Error error -> failwith (Format.asprintf "frame decode failed: %a" Frame.pp_error error)
        | Ok (state, frames) -> loop state (List.rev_append frames acc))
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> (state, List.rev acc)
  in
  loop state []

let pp_frames ppf frames =
  Format.fprintf ppf "[%a]" (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") Frame.pp) frames

let make_server ?(max_pending_bytes = 1_048_576) () =
  let ring = Ring.create ~capacity:64 in
  let policy = or_fail (policy ()) in
  let socket_path = fresh_socket_path () in
  let server =
    or_fail_err Observer_server.pp_error
      (Result.map_error Err.Error.kind (Observer_server.create ~socket_path ~ring ~policy ~max_pending_bytes))
  in
  (server, ring, socket_path)

let connect server socket_path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX socket_path);
  Observer_server.accept server;
  fd

let%expect_test "a fresh connection receives a snapshot with a cursor, and nothing before it" =
  let server, _ring, socket_path = make_server () in
  let outcome = make_outcome () in
  Observer_server.note_outcome server outcome;
  let fd = connect server socket_path in
  let _state, frames = read_frames (Frame.reader ()) fd in
  Format.printf "%a@." pp_frames frames;
  Observer_server.close server;
  [%expect
    {| [snapshot(authority(xterm-256color-core; max=80×24; no-reflow); snapshot(primary; 4×2; cursor=(1,0) visible=true; title=none; position=0; 8 cell(s)))] |}]

let%expect_test "a client that connects before any outcome exists waits, then receives its snapshot" =
  let server, _ring, socket_path = make_server () in
  let fd = connect server socket_path in
  let state, frames_before = read_frames (Frame.reader ()) fd in
  Format.printf "before outcome: %a@." pp_frames frames_before;
  Observer_server.note_outcome server (make_outcome ());
  let _state, frames_after = read_frames state fd in
  Format.printf "after outcome: %d frame(s)@." (List.length frames_after);
  Observer_server.close server;
  [%expect {|
    before outcome: []
    after outcome: 1 frame(s) |}]

let%expect_test "two independent connections (reconnect) each get their own fresh snapshot" =
  let server, _ring, socket_path = make_server () in
  Observer_server.note_outcome server (make_outcome ());
  let first = connect server socket_path in
  let _, first_frames = read_frames (Frame.reader ()) first in
  Unix.close first;
  let second = connect server socket_path in
  let _, second_frames = read_frames (Frame.reader ()) second in
  Format.printf "first=%d second=%d@." (List.length first_frames) (List.length second_frames);
  Observer_server.close server;
  [%expect {| first=1 second=1 |}]

let%expect_test "interleaved traffic/resize/effect records are delivered to a connected client in publish order" =
  let server, ring, socket_path = make_server () in
  Observer_server.note_outcome server (make_outcome ());
  let fd = connect server socket_path in
  let state, _initial = read_frames (Frame.reader ()) fd in
  let publish make =
    Ring.publish ring (make (Ring.next_sequence ring));
    Observer_server.drain server
  in
  publish (fun sequence ->
      Record.traffic ~sequence ~direction:Foundation.Types.Application_to_terminal ~bytes:(Bytes.of_string "a"));
  publish (fun sequence -> Record.resize ~sequence ~size:(or_fail (Tessera_test_support.Support.size 5 3)) ~pixels:None);
  publish (fun sequence ->
      Record.traffic ~sequence ~direction:Foundation.Types.Terminal_to_application ~bytes:(Bytes.of_string "b"));
  let _, frames = read_frames state fd in
  Format.printf "%a@." pp_frames frames;
  Observer_server.close server;
  [%expect
    {| [traffic(#0, application-to-terminal, 1 byte(s)); resize(#1, 5×3); traffic(#2, terminal-to-application, 1 byte(s))] |}]

let%expect_test "a burst that exceeds the pending-bytes bound resynchronises with a gap and a fresh snapshot" =
  let server, ring, socket_path = make_server ~max_pending_bytes:24 () in
  Observer_server.note_outcome server (make_outcome ());
  let fd = connect server socket_path in
  let state, _initial = read_frames (Frame.reader ()) fd in
  for i = 1 to 20 do
    Ring.publish ring
      (Record.traffic ~sequence:(Ring.next_sequence ring) ~direction:Foundation.Types.Application_to_terminal
         ~bytes:(Bytes.of_string (Printf.sprintf "payload-%02d" i)))
  done;
  Observer_server.drain server;
  let state, frames = read_frames state fd in
  let kinds =
    List.map
      (function
        | Frame.Gap _ -> "gap"
        | Frame.Authoritative_snapshot _ -> "snapshot"
        | Frame.Traffic _ -> "traffic"
        | Frame.Resize _ -> "resize"
        | Frame.Effect _ -> "effect")
      frames
  in
  Format.printf "%s@." (String.concat "," kinds);
  (* Converges: publishing one more record after the resync is delivered as ordinary streaming, not another gap. *)
  Ring.publish ring
    (Record.traffic ~sequence:(Ring.next_sequence ring) ~direction:Foundation.Types.Application_to_terminal
       ~bytes:(Bytes.of_string "tail"));
  Observer_server.drain server;
  let _, more = read_frames state fd in
  Format.printf "%a@." pp_frames more;
  Observer_server.close server;
  [%expect {|
    gap,snapshot
    [traffic(#20, application-to-terminal, 4 byte(s))] |}]

(* The one hard invariant from terminal-plan.md's "Proxy organisation": a slow/non-draining observer must never delay
   or alter the byte relay. The client here never reads at all; the relay is driven through the real fake-platform
   [Session], exactly like [contract_test.ml], and every relayed byte is checked against what was written. If
   [Observer_server]'s socket writes ever blocked, this test would hang instead of completing. *)
let%expect_test "a stalled, non-reading observer client never delays or corrupts the byte relay" =
  Fake_platform.set_physical_winsize (or_fail (winsize 4 2));
  let terminal_in_read, terminal_in_write = Unix.pipe () in
  let terminal_out_read, terminal_out_write = Unix.pipe () in
  let policy = or_fail (policy ()) in
  let lineage_id = Foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  let session =
    or_fail_err Session.Loop.pp_error
      (Session.create ~argv:[| "ignored" |] ~lineage_id ~policy ~terminal_in:terminal_in_read
         ~terminal_out:terminal_out_write ~observer_capacity:64 ~read_buffer_bytes:65536)
  in
  let server, _ring, socket_path = make_server ~max_pending_bytes:64 () in
  let _stalled_client = connect server socket_path in
  (* Never read from [_stalled_client]: it stays connected but silent for the rest of this test. *)
  let pty = Session.Loop.pty (Session.loop session) in
  let chunk = String.make 4096 'x' in
  let total_relayed = ref 0 in
  for _ = 1 to 40 do
    Fake_platform.push_child_bytes pty (Bytes.of_string chunk);
    (match Session.on_master_readable session with
    | Session.Application_bytes outcome -> Observer_server.note_outcome server outcome
    | _ -> failwith "expected application bytes");
    let relayed = Bytes.create (String.length chunk) in
    let rec read_all offset =
      if offset < String.length chunk then
        let n = Unix.read terminal_out_read relayed offset (String.length chunk - offset) in
        read_all (offset + n)
    in
    read_all 0;
    if not (Bytes.equal relayed (Bytes.of_string chunk)) then failwith "relay corrupted bytes";
    total_relayed := !total_relayed + Bytes.length relayed
  done;
  Format.printf "relayed %d bytes across a stalled observer connection without hanging@." !total_relayed;
  Observer_server.close server;
  Unix.close terminal_in_write;
  Unix.close terminal_out_read;
  [%expect {| relayed 163840 bytes across a stalled observer connection without hanging |}]

let%expect_test "create restricts both the socket's directory and the socket file itself to this user" =
  let server, _ring, socket_path = make_server () in
  let mode path = (Unix.stat path).Unix.st_perm land 0o777 in
  Format.printf "directory=%o socket=%o@." (mode (Filename.dirname socket_path)) (mode socket_path);
  Observer_server.close server;
  (match Unix.stat socket_path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Format.printf "unlinked after close: true@."
  | _ -> Format.printf "unlinked after close: false@.");
  [%expect {|
    directory=700 socket=600
    unlinked after close: true |}]
