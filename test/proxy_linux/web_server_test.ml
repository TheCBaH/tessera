(* Real-loopback-socket integration tests for Web_server: the HTTP static routes,
   the token/Origin-gated /session upgrade, and the tessera.proxy-web control-channel/tessera.web-frame message
   exchange over a real WebSocket, driven by a minimal client built on httpun-ws-lwt-unix's own Client module.

   Deliberately not exhaustive against every raw-frame-level edge case web_server.ml's implementation handles
   (RFC 6455 fragmentation sequencing, the close-code allow-list, the documented RSV/mask non-conformance
   exception): those need a client that constructs raw, possibly-invalid frames on purpose, which
   [Httpun_ws_lwt_unix.Client] (a conformant client) cannot do. This layer instead proves the well-behaved,
   real-client path end to end: static assets, auth, hello/ready/reset ordering and content, deltas, resize
   upgrade, resync-then-reconnect, a second Hello, and disconnect cleanup. *)

module Web_server = Tessera_proxy_linux.Web_server
module Control = Tessera_proxy_web_protocol.Control
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json
open Tessera_test_support.Support

let ( let* ) = Lwt.bind
let or_fail = function Ok value -> value | Error message -> failwith message
let or_fail_err pp = function Ok value -> value | Error error -> failwith (Format.asprintf "%a" pp error)
let server_pp ppf error = Web_server.pp_error ppf (Err.Error.kind error)

(* --- outcome helpers (mirrors test/proxy_web_publisher/web_publisher_test.ml) --- *)

let make_session ?(columns = 4) ?(rows = 2) () =
  let policy = or_fail (policy ()) in
  let lineage_id = Tessera_foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  Tessera.initial ~lineage_id ~policy ~size:(or_fail (size columns rows))

let session_pp ppf error = Tessera.Session.pp_error ppf (Err.Error.kind error)
let ingest_text session text = or_fail_err session_pp (Tessera.ingest session (Tessera.Bytes (or_fail (slice text))))

let ingest_resize session columns rows =
  or_fail_err session_pp (Tessera.ingest session (Tessera.Out_of_band (Tessera.Resize (or_fail (size columns rows)))))

let html_json_of_outcome ~patch outcome =
  let frame =
    or_fail_err
      (fun ppf e -> Frame.pp_error ppf (Err.Error.kind e))
      (Frame.of_outcome ~patch ~snapshot:(Tessera.outcome_snapshot outcome))
  in
  or_fail_err
    (fun ppf e -> Json.E.pp_error ppf (Err.Error.kind e))
    (Json.encode_html_frame (Json.html_envelope_of frame))

(* --- raw HTTP client (Lwt-based: a blocking Unix call here would starve the server's own accept loop, which
   shares this test's single Lwt_main.run) --- *)

let http_request ~port ~meth ~path ?(headers = []) () =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) in
  let request =
    Printf.sprintf "%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n%s\r\n" meth path port
      (String.concat "" (List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers))
  in
  let* (_ : int) = Lwt_unix.write_string socket request 0 (String.length request) in
  let buf = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec read_all () =
    let* n = Lwt_unix.read socket chunk 0 (Bytes.length chunk) in
    if n = 0 then Lwt.return_unit
    else begin
      Buffer.add_subbytes buf chunk 0 n;
      read_all ()
    end
  in
  let* () = read_all () in
  let* () = Lwt_unix.close socket in
  Lwt.return (Buffer.contents buf)

let status_line response =
  match String.index_opt response '\r' with Some i -> String.sub response 0 i | None -> response

(* --- WebSocket test client --- *)

type ws = {
  wsd : Httpun_ws.Wsd.t;
  socket : Lwt_unix.file_descr;
  incoming : string Queue.t;
  wake : unit Lwt_condition.t;
  mutable closed : bool;
}

(* Half-closes the underlying descriptor's *send* direction -- a raw TCP FIN from this client's side --
   rather than a full [Lwt_unix.close]: [Gluten_lwt_unix]'s per-connection read loop only ever exits once
   its own read hits actual socket EOF (see gluten_lwt.ml's [IO_loop.start]), and [Wsd.close] only closes
   the *write* side's Faraday buffer -- it never touches the OS descriptor, so neither alone delivers
   that EOF. [shutdown] (unlike [close]) only changes the socket's half-close state at the OS level; it
   does not deallocate the descriptor or race [Gluten_lwt_unix]'s own still-pending read on the same fd
   the way calling [close] on it from here was observed to (a tight scheduler spin, since that read loop
   and this call would then be contending over the fd's lifetime, not just its data). *)
let disconnect ws =
  Lwt.catch
    (fun () ->
      Lwt_unix.shutdown ws.socket Unix.SHUTDOWN_SEND;
      Lwt.return_unit)
    (fun _exn -> Lwt.return_unit)

(* [Httpun_ws_lwt_unix.Client.connect]'s own returned promise resolves once the underlying connection
   object is created, not once the WebSocket upgrade handshake actually completes -- [websocket_handler]
   is only invoked later, asynchronously, from inside the HTTP response handler that processes the
   server's 101 response (see [Client_connection.connect]'s [response_handler]). So this waits on its own
   promise, resolved by [websocket_handler] itself, rather than on [Client.connect]'s. *)
let connect_ws ~port ~token () =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) in
  let ws_promise, ws_resolver = Lwt.wait () in
  let websocket_handler wsd =
    let ws = { wsd; socket; incoming = Queue.create (); wake = Lwt_condition.create (); closed = false } in
    (* [Payload.schedule_read]'s [on_eof]/[on_read] are each one-shot -- see web_server.ml's
       [drain_payload] doc comment for the full explanation -- so a message spanning more than one
       Faraday chunk is only fully collected if [on_read] re-schedules. *)
    let rec drain payload ~on_read ~on_eof =
      Httpun_ws.Payload.schedule_read payload ~on_eof ~on_read:(fun bs ~off ~len ->
          on_read bs ~off ~len;
          drain payload ~on_read ~on_eof)
    in
    let frame ~opcode ~is_fin:_ ~len:_ payload =
      match opcode with
      | `Text ->
          let buf = Buffer.create 256 in
          drain payload
            ~on_read:(fun bs ~off ~len -> Buffer.add_string buf (Bigstringaf.substring bs ~off ~len))
            ~on_eof:(fun () ->
              Queue.push (Buffer.contents buf) ws.incoming;
              Lwt_condition.signal ws.wake ())
      | _ -> drain payload ~on_read:(fun _bs ~off:_ ~len:_ -> ()) ~on_eof:ignore
    in
    let eof ?error:_ () =
      ws.closed <- true;
      Lwt_condition.signal ws.wake ()
    in
    Lwt.wakeup_later ws_resolver ws;
    { Httpun_ws.Websocket_connection.frame; eof }
  in
  let* (_client : Httpun_ws_lwt_unix.Client.t) =
    Httpun_ws_lwt_unix.Client.connect ~nonce:"0123456789ABCDEF" ~host:"127.0.0.1" ~port
      ~resource:(Printf.sprintf "/session?token=%s" token)
      ~error_handler:(fun _ -> ())
      ~websocket_handler socket
  in
  ws_promise

let ws_send_client ws (message : Control.client_message) =
  let text = Control.encode_client_message message in
  let bytes = Bytes.of_string text in
  Httpun_ws.Wsd.send_bytes ws.wsd ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes);
  Lwt.return_unit

let rec ws_recv_raw ws =
  match Queue.take_opt ws.incoming with
  | Some text -> Lwt.return (Some text)
  | None -> if ws.closed then Lwt.return None else Lwt.bind (Lwt_condition.wait ws.wake) (fun () -> ws_recv_raw ws)

let ws_recv_raw_timeout ?(timeout = 2.0) ws =
  Lwt.pick [ ws_recv_raw ws; Lwt.map (fun () -> Some "<<timeout>>") (Lwt_unix.sleep timeout) ]

let describe text =
  match Json.decode_html_frame text with
  | Ok env -> Format.asprintf "%a" Frame.pp_kind env.meta.kind
  | Error _ -> (
      match Control.decode_server_message ~max_bytes:65536 text with
      | Ok m -> Format.asprintf "control:%a" Control.pp_server_message m
      | Error _ -> "undecodable")

(* --- test harness --- *)

let with_server ?(max_pending_bytes = 1_048_576) ?(write_timeout = 5.0) ?(close_flush_timeout = 1.0)
    ?(token = "test-token") f =
  let server =
    or_fail_err server_pp (Web_server.create ~port:0 ~token ~max_pending_bytes ~write_timeout ~close_flush_timeout ())
  in
  let stop, wake_stop = Lwt.wait () in
  let result =
    Lwt_main.run
      (let run_task = Web_server.run server ~stop in
       Lwt.pick
         [
           (let* result = f server in
            Lwt.wakeup_later wake_stop ();
            let* () = run_task in
            Lwt.return (Some result));
           Lwt.map (fun () -> None) (Lwt_unix.sleep 8.0);
         ])
  in
  Web_server.close server;
  match result with Some result -> result | None -> failwith "with_server: test body did not complete within 8s"

(* --- tests --- *)

let%expect_test "static routes: known GET routes 200, unknown 404, wrong method 405" =
  with_server (fun server ->
      let port = Web_server.port server in
      let* known =
        Lwt.all
          (List.map
             (fun path -> http_request ~port ~meth:"GET" ~path ())
             [
               "/";
               "/tessera.css";
               "/tessera-decode.js";
               "/tessera-driver.js";
               "/tessera-html-target.js";
               "/proxy-web.js";
               "/fonts/jetbrains-mono-latin-400-normal.woff2";
             ])
      in
      List.iter (fun r -> print_endline (status_line r)) known;
      let* unknown = http_request ~port ~meth:"GET" ~path:"/nope" () in
      print_endline (status_line unknown);
      let* wrong_method = http_request ~port ~meth:"POST" ~path:"/" () in
      print_endline (status_line wrong_method);
      Lwt.return_unit);
  [%expect
    {|
    HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    HTTP/1.1 200 OK
    HTTP/1.1 404 Not Found
    HTTP/1.1 405 Method Not Allowed |}]

let%expect_test "/session rejects a missing or wrong token, and a mismatched Origin, all before any upgrade" =
  with_server ~token:"right-token" (fun server ->
      let port = Web_server.port server in
      let* missing = http_request ~port ~meth:"GET" ~path:"/session" () in
      print_endline ("missing-token: " ^ status_line missing);
      let* wrong = http_request ~port ~meth:"GET" ~path:"/session?token=wrong" () in
      print_endline ("wrong-token: " ^ status_line wrong);
      let* wrong_origin =
        http_request ~port ~meth:"GET" ~path:"/session?token=right-token"
          ~headers:[ ("Origin", "http://evil.example") ]
          ()
      in
      print_endline ("wrong-origin: " ^ status_line wrong_origin);
      Format.printf "client_count=%d@." (Web_server.client_count server);
      Lwt.return_unit);
  [%expect
    {|
    missing-token: HTTP/1.1 403 Forbidden
    wrong-token: HTTP/1.1 403 Forbidden
    wrong-origin: HTTP/1.1 403 Forbidden
    client_count=0 |}]

let%expect_test "hello -> ready then reset (in that order), and the reset's content matches an independent oracle" =
  with_server (fun server ->
      let session = make_session () in
      let outcome = ingest_text session "hi" in
      Web_server.note_outcome server outcome;
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* first = ws_recv_raw_timeout ws in
      let* second = ws_recv_raw_timeout ws in
      (match first with
      | Some text ->
          Format.printf "1st: %a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text))
      | None -> print_endline "1st: <<none>>");
      (match second with
      | Some text ->
          let expected = html_json_of_outcome ~patch:None outcome in
          Format.printf "2nd: %s equal-to-oracle=%b@." (describe text) (String.equal text expected)
      | None -> print_endline "2nd: <<none>>");
      Lwt.return_unit);
  [%expect
    {|
    1st: ready(id="h1", capabilities(observe=true, input=false, resize=false))
    2nd: reset equal-to-oracle=true |}]

let%expect_test "a later outcome is delivered as a delta with content matching an independent oracle" =
  with_server (fun server ->
      let session = make_session () in
      Web_server.note_outcome server (ingest_text session "hi");
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_reset : string option) = ws_recv_raw_timeout ws in
      let second = ingest_text session "!!" in
      Web_server.note_outcome server second;
      let* delta = ws_recv_raw_timeout ws in
      (match delta with
      | Some text ->
          let expected = html_json_of_outcome ~patch:(Some (Tessera.outcome_patch second)) second in
          Format.printf "%s equal-to-oracle=%b@." (describe text) (String.equal text expected)
      | None -> print_endline "<<none>>");
      Lwt.return_unit);
  [%expect {| delta equal-to-oracle=true |}]

let%expect_test "a resize upgrades the next message to a reset" =
  with_server (fun server ->
      let session = make_session () in
      Web_server.note_outcome server (ingest_text session "hi");
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_reset : string option) = ws_recv_raw_timeout ws in
      Web_server.note_outcome server (ingest_resize session 6 3);
      let* after_resize = ws_recv_raw_timeout ws in
      print_endline (Option.fold ~none:"<<none>>" ~some:describe after_resize);
      Lwt.return_unit);
  [%expect {| reset |}]

let%expect_test "resync replies Result then closes with no corrective frame; a fresh connection is accepted" =
  with_server (fun server ->
      let session = make_session () in
      Web_server.note_outcome server (ingest_text session "hi");
      let port = Web_server.port server in
      let* ws = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_reset : string option) = ws_recv_raw_timeout ws in
      let* () = ws_send_client ws (Control.Resync { id = "r1" }) in
      let* result = ws_recv_raw_timeout ws in
      (match result with
      | Some text ->
          Format.printf "reply: %a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text))
      | None -> print_endline "reply: <<none>>");
      let* () = disconnect ws in
      (* A brand-new connection (mirroring proxy-web.js's own close+reconnect) is accepted unconditionally. *)
      let* ws2 = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client ws2 (Control.Hello { id = "h2"; target = Control.Html }) in
      let* (_ready2 : string option) = ws_recv_raw_timeout ws2 in
      let* reset2 = ws_recv_raw_timeout ws2 in
      print_endline (Option.fold ~none:"<<none>>" ~some:describe reset2);
      Lwt.return_unit);
  [%expect {|
    reply: result(id="r1")
    reset |}]

let%expect_test "a second hello on an attached connection is rejected with the second hello's own id, then closed" =
  with_server (fun server ->
      let session = make_session () in
      Web_server.note_outcome server (ingest_text session "hi");
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_reset : string option) = ws_recv_raw_timeout ws in
      let* () = ws_send_client ws (Control.Hello { id = "h2"; target = Control.Html }) in
      let* reply = ws_recv_raw_timeout ws in
      (match reply with
      | Some text ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text))
      | None -> print_endline "<<none>>");
      let* () = disconnect ws in
      Lwt.return_unit);
  [%expect {| error(id="h2", "already attached") |}]

let%expect_test "an ungraceful TCP half-close detaches its attached publisher client" =
  with_server (fun server ->
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let rec wait_for_detach attempts =
        if Web_server.client_count server = 0 then Lwt.return true
        else if attempts = 0 then Lwt.return false
        else Lwt.bind (Lwt_unix.sleep 0.01) (fun () -> wait_for_detach (attempts - 1))
      in
      let* () = disconnect ws in
      let* detached = wait_for_detach 100 in
      Format.printf "detached=%b client_count=%d@." detached (Web_server.client_count server);
      Lwt.return_unit);
  [%expect {| detached=true client_count=0 |}]
