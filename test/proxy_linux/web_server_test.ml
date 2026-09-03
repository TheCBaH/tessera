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
  let* result = Lwt.pick [ ws_recv_raw ws; Lwt.map (fun () -> Some "<<timeout>>") (Lwt_unix.sleep timeout) ] in
  (* A frame callback can fill [incoming] in the tiny interval after [ws_recv_raw] sees its queue empty and before it
     registers the condition waiter.  Conditions intentionally do not retain a signal, so recheck once on timeout. *)
  match result with
  | Some "<<timeout>>" -> Lwt.return (Some (Option.value ~default:"<<timeout>>" (Queue.take_opt ws.incoming)))
  | _ -> Lwt.return result

let describe text =
  match Json.decode_html_frame text with
  | Ok env -> Format.asprintf "%a" Frame.pp_kind env.meta.kind
  | Error _ -> (
      match Control.decode_server_message ~max_bytes:65536 text with
      | Ok m -> Format.asprintf "control:%a" Control.pp_server_message m
      | Error _ -> "undecodable")

(* --- raw WebSocket frame client ---

   [Httpun_ws_lwt_unix.Client] (used by [connect_ws] above) is itself RFC 6455-conformant: it always masks,
   never sets an RSV bit, and never emits a malformed close/fragmentation sequence, so it cannot exercise
   any of the raw-frame-level behaviour [web_server.ml] itself implements (the fragmentation state machine,
   the close-code allow-list, the documented RSV/mask non-conformance exception). This client constructs
   frames byte-for-byte instead, including deliberately non-conformant ones, and is used only by the tests
   below that need that. *)
module Raw_ws = struct
  let write_exact fd bytes =
    let len = Bytes.length bytes in
    let rec loop off =
      if off >= len then Lwt.return_unit
      else Lwt.bind (Lwt_unix.write fd bytes off (len - off)) (fun n -> loop (off + n))
    in
    loop 0

  let read_exact fd len =
    let bytes = Bytes.create len in
    let rec loop off =
      if off >= len then Lwt.return bytes
      else
        Lwt.bind
          (Lwt_unix.read fd bytes off (len - off))
          (fun n -> if n = 0 then Lwt.fail End_of_file else loop (off + n))
    in
    loop 0

  (* Completes the HTTP/1.1 upgrade handshake by hand over a raw socket, then hands back that socket for
     [send_frame]/[recv_frame] to drive directly. Reading the response headers one byte at a time is fine
     here: they are tiny and fixed-shape, and (unlike a real session) nothing else is on the wire yet for a
     byte-at-a-time read to over-consume. *)
  (* [rcvbuf], when given, shrinks this socket's own receive buffer *before* [connect] -- so the
     shrunk size is what the kernel actually negotiates as the initial TCP window, rather than only
     taking effect for later window updates the way setting it after [connect] would. Only meaningful
     for a caller that then never reads from this socket (see the write_timeout test below): the point
     is to make the server's own writes to it back up quickly and deterministically, independent of
     the host's default socket buffer sizing. *)
  let connect ?rcvbuf ~port ~token () =
    let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Option.iter (fun n -> try Lwt_unix.setsockopt_int socket Unix.SO_RCVBUF n with Unix.Unix_error _ -> ()) rcvbuf;
    let* () = Lwt_unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) in
    let request =
      Printf.sprintf
        "GET /session?token=%s HTTP/1.1\r\n\
         Host: 127.0.0.1:%d\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\n\
         \r\n"
        token port
    in
    let* (_ : int) = Lwt_unix.write_string socket request 0 (String.length request) in
    let buf = Buffer.create 256 in
    let byte = Bytes.create 1 in
    let rec read_headers () =
      let* n = Lwt_unix.read socket byte 0 1 in
      if n = 0 then Lwt.fail End_of_file
      else begin
        Buffer.add_char buf (Bytes.get byte 0);
        let s = Buffer.contents buf in
        let len = String.length s in
        if len >= 4 && String.equal (String.sub s (len - 4) 4) "\r\n\r\n" then Lwt.return s else read_headers ()
      end
    in
    let* headers = read_headers () in
    Lwt.return (socket, status_line headers)

  (* [mask:false]/[rsv1:true] deliberately produce non-conformant framing on purpose -- see the module doc
     comment above. Payloads used by these tests always fit in a 16-bit extended length. *)
  let send_frame socket ?(fin = true) ?(rsv1 = false) ?(mask = true) ~opcode payload =
    let len = String.length payload in
    let b0 = (if fin then 0x80 else 0) lor (if rsv1 then 0x40 else 0) lor (opcode land 0x0f) in
    let header = Buffer.create 14 in
    Buffer.add_char header (Char.chr b0);
    let mask_bit = if mask then 0x80 else 0 in
    if len < 126 then Buffer.add_char header (Char.chr (mask_bit lor len))
    else begin
      Buffer.add_char header (Char.chr (mask_bit lor 126));
      Buffer.add_char header (Char.chr ((len lsr 8) land 0xff));
      Buffer.add_char header (Char.chr (len land 0xff))
    end;
    let mask_key = if mask then Some (String.init 4 (fun _ -> Char.chr (Random.int 256))) else None in
    Option.iter (Buffer.add_string header) mask_key;
    let masked_payload =
      match mask_key with
      | None -> payload
      | Some key -> String.init len (fun i -> Char.chr (Char.code payload.[i] lxor Char.code key.[i mod 4]))
    in
    Buffer.add_string header masked_payload;
    write_exact socket (Buffer.to_bytes header)

  type frame = { fin : bool; rsv1 : bool; opcode : int; payload : string }

  let recv_frame socket =
    let* header = read_exact socket 2 in
    let b0 = Char.code (Bytes.get header 0) in
    let b1 = Char.code (Bytes.get header 1) in
    let fin = b0 land 0x80 <> 0 in
    let rsv1 = b0 land 0x40 <> 0 in
    let opcode = b0 land 0x0f in
    let masked = b1 land 0x80 <> 0 in
    let len7 = b1 land 0x7f in
    let* payload_len =
      if len7 = 126 then
        let* ext = read_exact socket 2 in
        Lwt.return ((Char.code (Bytes.get ext 0) lsl 8) lor Char.code (Bytes.get ext 1))
      else Lwt.return len7
    in
    let* mask_key = if masked then Lwt.map Option.some (read_exact socket 4) else Lwt.return None in
    let* payload = read_exact socket payload_len in
    (match mask_key with
    | None -> ()
    | Some key ->
        for i = 0 to payload_len - 1 do
          Bytes.set payload i (Char.chr (Char.code (Bytes.get payload i) lxor Char.code (Bytes.get key (i mod 4))))
        done);
    Lwt.return { fin; rsv1; opcode; payload = Bytes.to_string payload }

  let recv_frame_timeout ?(timeout = 2.0) socket =
    Lwt.pick [ Lwt.map Option.some (recv_frame socket); Lwt.map (fun () -> None) (Lwt_unix.sleep timeout) ]

  let close socket = Lwt.catch (fun () -> Lwt_unix.close socket) (fun _exn -> Lwt.return_unit)

  let opcode_name = function
    | 0x0 -> "continuation"
    | 0x1 -> "text"
    | 0x2 -> "binary"
    | 0x8 -> "close"
    | 0x9 -> "ping"
    | 0xa -> "pong"
    | n -> Printf.sprintf "other(%d)" n

  let close_code payload =
    if String.length payload < 2 then None else Some ((Char.code payload.[0] lsl 8) lor Char.code payload.[1])
end

(* Reads raw frames until (and including) the terminal Close frame, describing each as [(kind, payload)];
   [kind] is ["close(code=<n>)"] for that terminal frame so callers never need a separate case for it. *)
let recv_until_close socket =
  let rec loop acc =
    let* frame = Raw_ws.recv_frame_timeout socket in
    match frame with
    | None -> Lwt.return (List.rev (("<<timeout>>", "") :: acc))
    | Some { Raw_ws.opcode = 0x8; payload; _ } ->
        let code = match Raw_ws.close_code payload with Some c -> string_of_int c | None -> "<<none>>" in
        Lwt.return (List.rev ((Printf.sprintf "close(code=%s)" code, "") :: acc))
    | Some { Raw_ws.opcode; payload; _ } -> loop ((Raw_ws.opcode_name opcode, payload) :: acc)
  in
  loop []

let print_frames ?(label = "") frames =
  let prefix = if String.equal label "" then "" else label ^ ": " in
  List.iter
    (fun (kind, payload) ->
      let rendered =
        if String.equal kind "text" then
          match Control.decode_server_message ~max_bytes:65536 payload with
          | Ok m -> Format.asprintf "%a" Control.pp_server_message m
          | Error _ -> payload
        else kind
      in
      Format.printf "%s%s@." prefix rendered)
    frames

(* --- test harness --- *)

let with_server ?(max_pending_bytes = 1_048_576) ?(write_timeout = 5.0) ?(close_flush_timeout = 1.0)
    ?(token = "test-token") ?(overall_timeout = 8.0) ?input ?allow_control f =
  let server =
    or_fail_err server_pp
      (Web_server.create ~port:0 ~token ?input ?allow_control ~max_pending_bytes ~write_timeout ~close_flush_timeout ())
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
           Lwt.map (fun () -> None) (Lwt_unix.sleep overall_timeout);
         ])
  in
  Web_server.close server;
  match result with
  | Some result -> result
  | None -> failwith (Printf.sprintf "with_server: test body did not complete within %.1fs" overall_timeout)

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

let%expect_test "hello -> ready, generation-coupled input state, then reset" =
  with_server (fun server ->
      let session = make_session () in
      let outcome = ingest_text session "hi" in
      Web_server.note_outcome server outcome;
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* first = ws_recv_raw_timeout ws in
      let* second = ws_recv_raw_timeout ws in
      let* third = ws_recv_raw_timeout ws in
      (match first with
      | Some text ->
          Format.printf "1st: %a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text))
      | None -> print_endline "1st: <<none>>");
      (match second with
      | Some text ->
          Format.printf "2nd: %a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text))
      | None -> print_endline "2nd: <<none>>");
      (match third with
      | Some text ->
          let expected = html_json_of_outcome ~patch:None outcome in
          Format.printf "3rd: %s equal-to-oracle=%b@." (describe text) (String.equal text expected)
      | None -> print_endline "3rd: <<none>>");
      Lwt.return_unit);
  [%expect
    {|
    1st: ready(id="h1", capabilities(observe=true, input=false, resize=false))
    2nd: input-state(generation=1, cursor=false, keypad=false, paste=false, focus=false, tracking=off, encoding=default)
    3rd: reset equal-to-oracle=true |}]

let%expect_test "a later outcome publishes its matching input-state before its frame" =
  with_server (fun server ->
      let session = make_session () in
      let first = ingest_text session "hi" in
      Web_server.note_outcome server first;
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_state : string option) = ws_recv_raw_timeout ws in
      let* (_reset : string option) = ws_recv_raw_timeout ws in
      let second = ingest_text (Tessera.session first) "!!" in
      Web_server.note_outcome server second;
      let* state = ws_recv_raw_timeout ws in
      (match state with
      | Some text ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text))
      | None -> print_endline "<<none>>");
      Lwt.return_unit);
  [%expect
    {|
    input-state(generation=2, cursor=false, keypad=false, paste=false, focus=false, tracking=off, encoding=default) |}]

let%expect_test "a resize outcome publishes its matching input-state before its reset" =
  with_server (fun server ->
      let session = make_session () in
      let first = ingest_text session "hi" in
      Web_server.note_outcome server first;
      let* ws = connect_ws ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_state : string option) = ws_recv_raw_timeout ws in
      let* (_reset : string option) = ws_recv_raw_timeout ws in
      Web_server.note_outcome server (ingest_resize (Tessera.session first) 6 3);
      let* state = ws_recv_raw_timeout ws in
      Option.iter
        (fun text ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 text)))
        state;
      Lwt.return_unit);
  [%expect
    {|
    input-state(generation=2, cursor=false, keypad=false, paste=false, focus=false, tracking=off, encoding=default) |}]

let%expect_test "an explicitly enabled single controller lease authorizes bounded input and yields physical input" =
  let accepted = ref [] in
  let input bytes =
    accepted := Bytes.to_string bytes :: !accepted;
    Ok ()
  in
  with_server ~allow_control:true ~input (fun server ->
      let port = Web_server.port server in
      let* ws1 = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client ws1 (Control.Hello { id = "h1"; target = Control.Html }) in
      let* ready1 = ws_recv_raw_timeout ws1 in
      let* ws2 = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client ws2 (Control.Hello { id = "h2"; target = Control.Html }) in
      let* (_ready2 : string option) = ws_recv_raw_timeout ws2 in
      Format.printf "ready=%a physical_input_allowed_initial=%b@." Control.pp_server_message
        (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 (Option.get ready1)))
        (Web_server.physical_input_allowed server);
      let* () = ws_send_client ws1 (Control.Acquire_control { id = "a1" }) in
      let* acquired = ws_recv_raw_timeout ws1 in
      let* () = ws_send_client ws2 (Control.Acquire_control { id = "a2" }) in
      let* denied = ws_recv_raw_timeout ws2 in
      let* () = ws_send_client ws1 (Control.Input { id = "i1"; bytes = Bytes.of_string "paste\000ok" }) in
      let* accepted_reply = ws_recv_raw_timeout ws1 in
      List.iter
        (fun text ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 (Option.get text))))
        [ acquired; denied; accepted_reply ];
      Format.printf "physical_input_allowed_leased=%b accepted=%S@."
        (Web_server.physical_input_allowed server)
        (String.concat "," (List.rev !accepted));
      let* () = ws_send_client ws1 (Control.Release_control { id = "r1" }) in
      let* released = ws_recv_raw_timeout ws1 in
      Format.printf "%a physical_input_allowed_released=%b@." Control.pp_server_message
        (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 (Option.get released)))
        (Web_server.physical_input_allowed server);
      Lwt.return_unit);
  [%expect
    {|
    ready=ready(id="h1", capabilities(observe=true, input=true, resize=false)) physical_input_allowed_initial=true
    result(id="a1")
    error(id="a2", "controller lease is held by another client")
    result(id="i1")
    physical_input_allowed_leased=false accepted="paste\000ok"
    result(id="r1") physical_input_allowed_released=true |}]

let%expect_test "resync replies Result then closes with no corrective frame; a fresh connection is accepted" =
  with_server (fun server ->
      let session = make_session () in
      Web_server.note_outcome server (ingest_text session "hi");
      let port = Web_server.port server in
      let* ws = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_state : string option) = ws_recv_raw_timeout ws in
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
      let* (_state2 : string option) = ws_recv_raw_timeout ws2 in
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
      let* (_state : string option) = ws_recv_raw_timeout ws in
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

(* --- raw-frame-level tests: fragmentation, close-code allow-list, control-frame draining, the documented
   RSV/mask exception, and Error.id correlation. See lib/proxy_linux/web_server.mli for the
   normative behaviour each of these checks. *)

let%expect_test "a Continuation frame with no prior unfinished text is a protocol violation" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = Raw_ws.send_frame socket ~opcode:0x0 "oops" in
      let* frames = recv_until_close socket in
      print_frames frames;
      Raw_ws.close socket);
  [%expect {|
    error(id=none, "continuation with no prior text")
    close(code=1002) |}]

let%expect_test "a second Text frame opened before a prior fragmented one completes is a protocol violation" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = Raw_ws.send_frame socket ~opcode:0x1 ~fin:false "part-one" in
      let* () = Raw_ws.send_frame socket ~opcode:0x1 ~fin:true "part-two" in
      let* frames = recv_until_close socket in
      print_frames frames;
      Raw_ws.close socket);
  [%expect {|
    error(id=none, "text frame while one is unfinished")
    close(code=1002) |}]

let%expect_test "a Hello fragmented across three Continuation frames is processed identically to an unfragmented one" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let hello = Control.encode_client_message (Control.Hello { id = "h1"; target = Control.Html }) in
      let len = String.length hello in
      let third = len / 3 in
      let part1 = String.sub hello 0 third in
      let part2 = String.sub hello third third in
      let part3 = String.sub hello (2 * third) (len - (2 * third)) in
      let* () = Raw_ws.send_frame socket ~opcode:0x1 ~fin:false part1 in
      let* () = Raw_ws.send_frame socket ~opcode:0x0 ~fin:false part2 in
      let* () = Raw_ws.send_frame socket ~opcode:0x0 ~fin:true part3 in
      let* reply = Raw_ws.recv_frame_timeout socket in
      (match reply with
      | Some { Raw_ws.opcode = 0x1; payload; _ } ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 payload))
      | Some { Raw_ws.opcode; _ } -> Format.printf "unexpected opcode %s@." (Raw_ws.opcode_name opcode)
      | None -> print_endline "<<timeout>>");
      Raw_ws.close socket);
  [%expect {| ready(id="h1", capabilities(observe=true, input=false, resize=false)) |}]

let%expect_test
    "a Ping interleaved between fragments of an in-progress Hello is answered, and the Hello still completes afterward"
    =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let hello = Control.encode_client_message (Control.Hello { id = "h1"; target = Control.Html }) in
      let mid = String.length hello / 2 in
      let part1 = String.sub hello 0 mid in
      let part2 = String.sub hello mid (String.length hello - mid) in
      let* () = Raw_ws.send_frame socket ~opcode:0x1 ~fin:false part1 in
      let* () = Raw_ws.send_frame socket ~opcode:0x9 "hi" in
      let* pong = Raw_ws.recv_frame_timeout socket in
      (match pong with
      | Some { Raw_ws.opcode = 0xa; payload; _ } -> Format.printf "pong payload=%S@." payload
      | Some { Raw_ws.opcode; _ } -> Format.printf "unexpected opcode %s@." (Raw_ws.opcode_name opcode)
      | None -> print_endline "<<timeout>>");
      let* () = Raw_ws.send_frame socket ~opcode:0x0 part2 in
      let* ready = Raw_ws.recv_frame_timeout socket in
      (match ready with
      | Some { Raw_ws.opcode = 0x1; payload; _ } ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 payload))
      | Some { Raw_ws.opcode; _ } -> Format.printf "unexpected opcode %s@." (Raw_ws.opcode_name opcode)
      | None -> print_endline "<<timeout>>");
      Raw_ws.close socket);
  [%expect {|
    pong payload="hi"
    ready(id="h1", capabilities(observe=true, input=false, resize=false)) |}]

let%expect_test "a fragmented or oversized control frame is a protocol violation" =
  with_server (fun server ->
      let port = Web_server.port server in
      let check label ~fin ~payload =
        let* socket, _status = Raw_ws.connect ~port ~token:"test-token" () in
        let* () = Raw_ws.send_frame socket ~opcode:0x9 ~fin payload in
        let* frames = recv_until_close socket in
        print_frames ~label frames;
        Raw_ws.close socket
      in
      let* () = check "fragmented-ping" ~fin:false ~payload:"hi" in
      let* () = check "oversized-ping" ~fin:true ~payload:(String.make 126 'x') in
      Lwt.return_unit);
  [%expect {|
    fragmented-ping: close(code=1002)
    oversized-ping: close(code=1002) |}]

let%expect_test "a Binary frame is rejected as a protocol violation" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = Raw_ws.send_frame socket ~opcode:0x2 "binary is not supported" in
      let* frames = recv_until_close socket in
      print_frames frames;
      Raw_ws.close socket);
  [%expect {|
    error(id=none, "binary frames are not supported")
    close(code=1002) |}]

let%expect_test "a reserved/unknown opcode is rejected as a protocol violation" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = Raw_ws.send_frame socket ~opcode:0x3 "" in
      let* frames = recv_until_close socket in
      print_frames frames;
      Raw_ws.close socket);
  [%expect {|
    error(id=none, "reserved opcode")
    close(code=1002) |}]

let%expect_test "close-code allow-list: reserved/unassigned codes are rejected, sendable codes are echoed verbatim" =
  with_server (fun server ->
      let port = Web_server.port server in
      let check code =
        let* socket, _status = Raw_ws.connect ~port ~token:"test-token" () in
        let payload = Printf.sprintf "%c%cbye" (Char.chr (code lsr 8)) (Char.chr (code land 0xff)) in
        let* () = Raw_ws.send_frame socket ~opcode:0x8 payload in
        let* response = Raw_ws.recv_frame_timeout socket in
        let* () = Raw_ws.close socket in
        (match response with
        | Some { Raw_ws.opcode = 0x8; payload; _ } ->
            Format.printf "code=%d -> %s@." code
              (match Raw_ws.close_code payload with Some c -> string_of_int c | None -> "<<no code>>")
        | Some { Raw_ws.opcode; _ } ->
            Format.printf "code=%d -> unexpected opcode %s@." code (Raw_ws.opcode_name opcode)
        | None -> Format.printf "code=%d -> <<timeout>>@." code);
        Lwt.return_unit
      in
      Lwt_list.iter_s check [ 999; 1004; 1005; 1006; 1015; 2000; 1000; 1012; 1013; 1014; 3001; 4001 ]);
  [%expect
    {|
    code=999 -> 1002
    code=1004 -> 1002
    code=1005 -> 1002
    code=1006 -> 1002
    code=1015 -> 1002
    code=2000 -> 1002
    code=1000 -> 1000
    code=1012 -> 1012
    code=1013 -> 1013
    code=1014 -> 1014
    code=3001 -> 3001
    code=4001 -> 4001 |}]

let%expect_test "a Connection_close payload's length and reason UTF-8 are validated" =
  with_server (fun server ->
      let port = Web_server.port server in
      let check label payload =
        let* socket, _status = Raw_ws.connect ~port ~token:"test-token" () in
        let* () = Raw_ws.send_frame socket ~opcode:0x8 payload in
        let* frames = recv_until_close socket in
        print_frames ~label frames;
        Raw_ws.close socket
      in
      let* () = check "empty-payload" "" in
      let* () = check "one-byte-payload" "\x00" in
      let* () = check "invalid-utf8-reason" "\x03\xe8\xff\xfe" in
      Lwt.return_unit);
  [%expect
    {|
    empty-payload: close(code=1000)
    one-byte-payload: close(code=1002)
    invalid-utf8-reason: close(code=1002) |}]

let%expect_test
    "a Ping with a non-empty payload is echoed verbatim by Pong, and a following message is still processed (the \
     payload-draining stall fix)" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = Raw_ws.send_frame socket ~opcode:0x9 "ping-payload" in
      let* pong = Raw_ws.recv_frame_timeout socket in
      (match pong with
      | Some { Raw_ws.opcode = 0xa; payload; _ } -> Format.printf "pong payload=%S@." payload
      | Some { Raw_ws.opcode; _ } -> Format.printf "unexpected opcode %s@." (Raw_ws.opcode_name opcode)
      | None -> print_endline "<<timeout>>");
      let* () =
        Raw_ws.send_frame socket ~opcode:0x1
          (Control.encode_client_message (Control.Hello { id = "h1"; target = Control.Html }))
      in
      let* ready = Raw_ws.recv_frame_timeout socket in
      (match ready with
      | Some { Raw_ws.opcode = 0x1; payload; _ } ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 payload))
      | Some { Raw_ws.opcode; _ } -> Format.printf "unexpected opcode %s@." (Raw_ws.opcode_name opcode)
      | None -> print_endline "<<timeout>>");
      Raw_ws.close socket);
  [%expect
    {|
    pong payload="ping-payload"
    ready(id="h1", capabilities(observe=true, input=false, resize=false)) |}]

let%expect_test "a Pong with a non-empty payload is silently drained and does not stall a following message" =
  with_server (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let* () = Raw_ws.send_frame socket ~opcode:0xa "unsolicited-pong-payload" in
      let* () =
        Raw_ws.send_frame socket ~opcode:0x1
          (Control.encode_client_message (Control.Hello { id = "h1"; target = Control.Html }))
      in
      let* ready = Raw_ws.recv_frame_timeout socket in
      (match ready with
      | Some { Raw_ws.opcode = 0x1; payload; _ } ->
          Format.printf "%a@." Control.pp_server_message
            (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 payload))
      | Some { Raw_ws.opcode; _ } -> Format.printf "unexpected opcode %s@." (Raw_ws.opcode_name opcode)
      | None -> print_endline "<<timeout>>");
      Raw_ws.close socket);
  [%expect {| ready(id="h1", capabilities(observe=true, input=false, resize=false)) |}]

let%expect_test
    "an unmasked client frame and a frame with an RSV bit set are both accepted, not rejected (the documented \
     httpun-ws 0.2.0 compatibility exception -- see web_server.mli)" =
  with_server (fun server ->
      let port = Web_server.port server in
      let hello id = Control.encode_client_message (Control.Hello { id; target = Control.Html }) in
      let check label ~mask ~rsv1 id =
        let* socket, _status = Raw_ws.connect ~port ~token:"test-token" () in
        let* () = Raw_ws.send_frame socket ~mask ~rsv1 ~opcode:0x1 (hello id) in
        let* reply = Raw_ws.recv_frame_timeout socket in
        (match reply with
        | Some { Raw_ws.opcode = 0x1; payload; _ } ->
            Format.printf "%s: %a@." label Control.pp_server_message
              (or_fail_err Control.E.Error.pp_kind (Control.decode_server_message ~max_bytes:65536 payload))
        | Some { Raw_ws.opcode; _ } -> Format.printf "%s: unexpected opcode %s@." label (Raw_ws.opcode_name opcode)
        | None -> Format.printf "%s: <<timeout>>@." label);
        Raw_ws.close socket
      in
      let* () = check "unmasked" ~mask:false ~rsv1:false "h1" in
      let* () = check "rsv1-set" ~mask:true ~rsv1:true "h2" in
      Lwt.return_unit);
  [%expect
    {|
    unmasked: ready(id="h1", capabilities(observe=true, input=false, resize=false))
    rsv1-set: ready(id="h2", capabilities(observe=true, input=false, resize=false)) |}]

let%expect_test "Error.id is null for a connection-level failure that never decoded a client id" =
  with_server (fun server ->
      let port = Web_server.port server in
      let check label send =
        let* socket, _status = Raw_ws.connect ~port ~token:"test-token" () in
        let* () = send socket in
        let* frames = recv_until_close socket in
        print_frames ~label frames;
        Raw_ws.close socket
      in
      (* The malformed-JSON case's own [Error.message] is Jsont's diagnostic text, which can carry ANSI
         styling depending on the process's global [Fmt] style-renderer state (e.g. a real tty locally vs
         CI's non-tty) -- printed here via [Control.pp_error]'s domain-kind rendering (["json"], with no
         message text) rather than [print_frames]'s verbatim wire content, to avoid a spurious
         environment-specific mismatch on text this test doesn't otherwise care about. *)
      let* malformed_socket, _status = Raw_ws.connect ~port ~token:"test-token" () in
      let* () = Raw_ws.send_frame malformed_socket ~opcode:0x1 "{not json" in
      let* malformed_frames = recv_until_close malformed_socket in
      List.iter
        (fun (kind, payload) ->
          if String.equal kind "text" then
            match Control.decode_server_message ~max_bytes:65536 payload with
            | Ok (Control.Error { id = None; message }) ->
                Format.printf "malformed-json: error(id=none, is_json_error=%b)@."
                  (String.length message >= 5 && String.equal (String.sub message 0 5) "json(")
            | Ok other -> Format.printf "malformed-json: unexpected %a@." Control.pp_server_message other
            | Error _ -> print_endline "malformed-json: undecodable"
          else Format.printf "malformed-json: %s@." kind)
        malformed_frames;
      let* () = Raw_ws.close malformed_socket in
      let* () = check "reserved-opcode" (fun socket -> Raw_ws.send_frame socket ~opcode:0x3 "") in
      Lwt.return_unit);
  [%expect
    {|
    malformed-json: error(id=none, is_json_error=true)
    malformed-json: close(code=1002)
    reserved-opcode: error(id=none, "reserved opcode")
    reserved-opcode: close(code=1002) |}]

let%expect_test "a protocol violation closes the connection within close_flush_timeout" =
  with_server ~close_flush_timeout:0.2 (fun server ->
      let* socket, _status = Raw_ws.connect ~port:(Web_server.port server) ~token:"test-token" () in
      let started = Unix.gettimeofday () in
      let* () = Raw_ws.send_frame socket ~opcode:0x2 "binary is not allowed" in
      let rec drain_to_eof () =
        let probe = Bytes.create 4096 in
        let* n = Lwt_unix.read socket probe 0 4096 in
        if n = 0 then Lwt.return_unit else drain_to_eof ()
      in
      let* () = drain_to_eof () in
      let elapsed = Unix.gettimeofday () -. started in
      Format.printf "closed_within_bound=%b@." (Float.compare elapsed 2.0 < 0);
      Raw_ws.close socket);
  [%expect {| closed_within_bound=true |}]

let%expect_test "a tiny max_pending_bytes forces a fresh Reset instead of a queued Delta at the transport layer" =
  with_server ~max_pending_bytes:64 (fun server ->
      let port = Web_server.port server in
      let session = make_session () in
      Web_server.note_outcome server (ingest_text session "hi");
      let* ws = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client ws (Control.Hello { id = "h1"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout ws in
      let* (_state : string option) = ws_recv_raw_timeout ws in
      let* first = ws_recv_raw_timeout ws in
      print_endline (Option.fold ~none:"<<none>>" ~some:describe first);
      (* Deliberately never drained above: with a 64-byte bound, one more outcome's Delta already exceeds
         it, so every message from here on must be a Reset, never a stray Delta resumed after the drop. *)
      for i = 1 to 5 do
        Web_server.note_outcome server (ingest_text session (Printf.sprintf "line-%d" i))
      done;
      let* second = ws_recv_raw_timeout ws in
      let* third = ws_recv_raw_timeout ws in
      print_endline (Option.fold ~none:"<<none>>" ~some:describe second);
      print_endline (Option.fold ~none:"<<none>>" ~some:describe third);
      disconnect ws);
  [%expect
    {|
    reset
    control:input-state(generation=1, cursor=false, keypad=false, paste=false, focus=false, tracking=off, encoding=default)
    reset |}]

let%expect_test "a stuck peer is force-closed by write_timeout, without perturbing another client's delivery" =
  with_server ~overall_timeout:45.0 ~write_timeout:0.2 ~max_pending_bytes:50_000_000 (fun server ->
      let port = Web_server.port server in
      let session = make_session ~columns:80 ~rows:24 () in
      (* [rcvbuf] must be set *before* [connect] (see [Raw_ws.connect]'s doc comment) -- setting it
         afterward only bounds future growth of an already-larger negotiated window, which is enough to
         overrun quickly on some hosts but not reliably on every kernel/host this runs against. *)
      let* stuck_socket, _status = Raw_ws.connect ~rcvbuf:1024 ~port ~token:"test-token" () in
      let* () =
        Raw_ws.send_frame stuck_socket ~opcode:0x1
          (Control.encode_client_message (Control.Hello { id = "stuck"; target = Control.Html }))
      in
      (* [stuck_socket] never reads again from here on. *)
      let* well_behaved = connect_ws ~port ~token:"test-token" () in
      let* () = ws_send_client well_behaved (Control.Hello { id = "ok"; target = Control.Html }) in
      let* (_ready : string option) = ws_recv_raw_timeout well_behaved in
      Format.printf "before_burst client_count=%d@." (Web_server.client_count server);
      (* Each step overwrites the same on-screen cell (a bare carriage return, no newline, so the grid never
         scrolls and every [ingest_text]/[note_outcome] call stays cheap regardless of how many precede it) --
         the burst relies on iteration count, not per-message size, to overrun [stuck_socket]'s shrunk receive
         buffer. *)
      let step i = "\r" ^ String.make 1 (Char.chr (65 + (i mod 26))) in
      (* [well_behaved] is deliberately never drained through the WebSocket protocol layer during the burst
         (that would need thousands of round trips through [Lwt.pick]/[Lwt_condition], dominating this
         test's wall time for no reason) -- instead its already-decoded backlog is discarded directly at
         each pause point, just to keep this test's own process memory bounded. *)
      let rec burst i =
        (* Bail out the moment the stuck client is gone rather than always running the full ceiling --
           keeps this fast on a host where a small backlog is already enough, while the high ceiling
           below is what makes it reliable on a host that needs much more. *)
        if i > 30_000 || Web_server.client_count server = 1 then Lwt.return_unit
        else begin
          Web_server.note_outcome server (ingest_text session (step i));
          if i mod 500 = 0 then begin
            Queue.clear well_behaved.incoming;
            Lwt.bind (Lwt.pause ()) (fun () -> burst (i + 1))
          end
          else burst (i + 1)
        end
      in
      let* () = burst 1 in
      let rec wait_for_detach attempts =
        if Web_server.client_count server = 1 then Lwt.return true
        else if attempts = 0 then Lwt.return false
        else Lwt.bind (Lwt_unix.sleep 0.05) (fun () -> wait_for_detach (attempts - 1))
      in
      let* detached = wait_for_detach 200 in
      (* [well_behaved] attached to the same target and never had its own backlog capped -- the meaningful
         claim here is that force-closing the stuck peer is targeted: [well_behaved]'s own connection (and
         publisher client) survives it untouched, rather than [write_timeout] or an exception anywhere in
         that path taking the whole server, or every other connection, down with it. *)
      Format.printf "stuck_client_force_closed=%b well_behaved_still_attached=%b@." detached
        (Web_server.client_count server = 1);
      let* () = Raw_ws.close stuck_socket in
      disconnect well_behaved);
  [%expect {|
    before_burst client_count=2
    stuck_client_force_closed=true well_behaved_still_attached=true |}]
