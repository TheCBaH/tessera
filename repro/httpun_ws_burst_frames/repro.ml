(* Standalone probe: does httpun-ws-lwt-unix/gluten-lwt dispatch every already-received WebSocket text
   frame to the application, or does it strand frames past the first one when many arrive together in a
   single underlying socket read and nothing further is sent afterward?

   The server acks each frame it dispatches with its own text reply, synchronously, exactly like
   tessera-proxy's web_server.ml does for "input" control messages. The client sends [n] small text
   frames back-to-back with no yield in between (mirroring a real client's tight keystroke burst), then
   waits. If gluten's read loop only advances its internal frame queue by one dispatch per actual socket
   read, and nothing more arrives on the wire afterward, dispatch will stop short of [n] and the process
   will time out instead of seeing all [n] acks. *)

open Lwt.Infix

let log message = Printf.printf "%s\n%!" message

let drain payload ~on_read =
  let rec go () =
    Httpun_ws.Payload.schedule_read payload
      ~on_eof:(fun () -> ())
      ~on_read:(fun bs ~off ~len ->
        on_read bs ~off ~len;
        go ())
  in
  go ()

let n = try int_of_string Sys.argv.(1) with _ -> 30

let server_websocket_handler wsd =
  let received = ref 0 in
  let frame ~opcode:_ ~is_fin:_ ~len:_ payload =
    drain payload ~on_read:(fun _bs ~off:_ ~len:_ -> ());
    incr received;
    let msg = Printf.sprintf "ack:%d" !received in
    let bytes = Bytes.of_string msg in
    Httpun_ws.Wsd.send_bytes wsd ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes)
  in
  let eof ?error:_ () = () in
  { Httpun_ws.Websocket_connection.frame; eof }

let sha1 value = value |> Digestif.SHA1.digest_string |> Digestif.SHA1.to_raw_string

let request_handler _addr (gluten_reqd : Httpun.Reqd.t Gluten.reqd) =
  let { Gluten.Reqd.reqd; upgrade } = gluten_reqd in
  let upgrade_handler () =
    let websocket = Httpun_ws.Server_connection.create_websocket server_websocket_handler in
    upgrade (Gluten.make (module Httpun_ws.Server_connection) websocket)
  in
  match Httpun_ws.Handshake.respond_with_upgrade ~sha1 reqd upgrade_handler with
  | Ok () -> ()
  | Error message -> Httpun.Reqd.respond_with_string reqd (Httpun.Response.create `Bad_request) message

let error_handler _addr ?request:_ (_ : Httpun.Reqd.error) handle =
  Httpun.Body.Writer.close (handle Httpun.Headers.empty)

let run () =
  let listen_fd = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listen_fd Unix.SO_REUSEADDR true;
  Unix.bind listen_fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listen_fd 16;
  Unix.set_nonblock listen_fd;
  let port = match Unix.getsockname listen_fd with Unix.ADDR_INET (_, port) -> port | _ -> assert false in
  let listen_lwt = Lwt_unix.of_unix_file_descr ~blocking:false listen_fd in
  let connection_handler = Httpun_lwt_unix.Server.create_connection_handler ~request_handler ~error_handler in
  let rec accept_loop () =
    Lwt_unix.wait_read listen_lwt >>= fun () ->
    (try
       let fd, addr = Unix.accept ~cloexec:true listen_fd in
       Unix.set_nonblock fd;
       Lwt.async (fun () -> connection_handler addr (Lwt_unix.of_unix_file_descr ~blocking:false fd))
     with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ());
    accept_loop ()
  in
  Lwt.async accept_loop;
  let client_ready, resolve_client_ready = Lwt.wait () in
  let acks_seen = ref 0 in
  let all_seen, resolve_all_seen = Lwt.wait () in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) >>= fun () ->
  let websocket_handler wsd =
    let frame ~opcode:_ ~is_fin:_ ~len:_ payload =
      drain payload ~on_read:(fun bs ~off ~len ->
          incr acks_seen;
          log (Printf.sprintf "client: got %s (count=%d)" (Bigstringaf.substring bs ~off ~len) !acks_seen);
          if !acks_seen = n then Lwt.wakeup_later resolve_all_seen ())
    in
    let eof ?error:_ () = () in
    Lwt.wakeup_later resolve_client_ready wsd;
    { Httpun_ws.Websocket_connection.frame; eof }
  in
  Httpun_ws_lwt_unix.Client.connect ~nonce:"0123456789ABCDEF" ~host:"127.0.0.1" ~port ~resource:"/"
    ~error_handler:(fun _ -> ())
    ~websocket_handler socket
  >>= fun _client ->
  client_ready >>= fun client_wsd ->
  log (Printf.sprintf "client: sending %d frames back-to-back, no yield" n);
  for i = 1 to n do
    let msg = Printf.sprintf "msg:%d" i in
    let bytes = Bytes.of_string msg in
    Httpun_ws.Wsd.send_bytes client_wsd ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes)
  done;
  Lwt.pick [ (all_seen >|= fun () -> `All_seen); (Lwt_unix.sleep 5.0 >|= fun () -> `Timeout) ] >>= fun result ->
  match result with
  | `All_seen ->
      log (Printf.sprintf "RESULT: PASS (all %d acks seen)" n);
      Lwt.return_unit
  | `Timeout ->
      log (Printf.sprintf "RESULT: FAIL (only %d/%d acks seen before timeout)" !acks_seen n);
      Lwt.return_unit

let () = Lwt_main.run (run ())
