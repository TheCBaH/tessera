module Publisher = Tessera_proxy_web_publisher.Web_publisher
module Control = Tessera_proxy_web_protocol.Control

type error =
  [ `Bind_failed of Unix.error
  | `Listen_failed of Unix.error
  | `Socket_failed of Unix.error
  | `Token_unavailable of Unix.error ]

let pp_error ppf = function
  | `Bind_failed code -> Format.fprintf ppf "bind-failed(%s)" (Unix.error_message code)
  | `Listen_failed code -> Format.fprintf ppf "listen-failed(%s)" (Unix.error_message code)
  | `Socket_failed code -> Format.fprintf ppf "socket-failed(%s)" (Unix.error_message code)
  | `Token_unavailable code -> Format.fprintf ppf "token-unavailable(%s)" (Unix.error_message code)

module Error_domain = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error_domain)
module Reqd = Httpun.Reqd
module Response = Httpun.Response
module Request = Httpun.Request
module Headers = Httpun.Headers
module Status = Httpun.Status
module Body = Httpun.Body

let ( let* ) = Result.bind
let max_control_message_bytes = 100_000

(* --- small helpers --- *)

let hex_encode bytes =
  let buf = Buffer.create (Bytes.length bytes * 2) in
  Bytes.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) bytes;
  Buffer.contents buf

let generate_token () =
  E.protect ~pos:__POS__
    ~catch:(function Unix.Unix_error (code, _, _) -> Some (`Token_unavailable code) | _ -> None)
    (fun () ->
      let fd = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
        (fun () ->
          let bytes = Bytes.create 16 in
          let rec read_all offset =
            if offset < 16 then
              let n = Unix.read fd bytes offset (16 - offset) in
              if n = 0 then failwith "unexpected eof reading /dev/urandom" else read_all (offset + n)
          in
          read_all 0;
          hex_encode bytes))

(* Constant-time by construction: every byte of both operands is always visited, and the accumulated
   difference is only inspected once at the end -- no comparison ever short-circuits on content. *)
let constant_time_equal a b =
  if String.length a <> String.length b then false
  else begin
    let diff = ref 0 in
    String.iteri (fun i c -> diff := !diff lor (Char.code c lxor Char.code b.[i])) a;
    !diff = 0
  end

let split_target target =
  match String.index_opt target '?' with
  | None -> (target, "")
  | Some i -> (String.sub target 0 i, String.sub target (i + 1) (String.length target - i - 1))

let query_param query name =
  String.split_on_char '&' query
  |> List.find_map (fun pair ->
      match String.index_opt pair '=' with
      | None -> if String.equal pair name then Some "" else None
      | Some i ->
          let key = String.sub pair 0 i in
          if String.equal key name then Some (String.sub pair (i + 1) (String.length pair - i - 1)) else None)

let valid_utf8 s =
  let length = String.length s in
  let rec loop offset =
    if offset >= length then true
    else
      let decode = String.get_utf_8_uchar s offset in
      Uchar.utf_decode_is_valid decode && loop (offset + Uchar.utf_decode_length decode)
  in
  loop 0

(* The RFC/IANA-assigned sendable status codes (1000-1003, 1007-1014), plus the IANA-registered
   library/application (3000-3999) and private-use (4000-4999) ranges. Deliberately not
   "Httpun_ws.Websocket.Close_code.of_code returned Some": that function's only built-in bound check is
   `code < 1000 || code > 0xffff`, so it happily maps the wire-illegal sentinels 1005/1006/1015 (and the
   unassigned 1004) to named `standard` constructors -- echoing one of those back would silently launder
   an invalid code as if it had been validated. *)
let close_code_allowed code =
  (code >= 1000 && code <= 1003)
  || (code >= 1007 && code <= 1014)
  || (code >= 3000 && code <= 3999)
  || (code >= 4000 && code <= 4999)

let sha1 s = s |> Digestif.SHA1.digest_string |> Digestif.SHA1.to_raw_string

(* --- per-connection state --- *)

type fragment_state = Idle | In_text of Buffer.t
type input_handler = bytes -> (unit, string) result

type conn = {
  wake : unit Lwt_condition.t;
  mutable state : [ `Awaiting_hello | `Attached of Publisher.client ];
  mutable fragment : fragment_state;
  mutable closing : bool;
  mutable cleaned_up : bool;
}

type connection_lifecycle = { fd : Lwt_unix.file_descr; mutable fd_closed : bool; mutable cleanup : unit -> unit }

type t = {
  listen_fd : Unix.file_descr;
  listen_lwt : Lwt_unix.file_descr;
  port : int;
  token : string;
  publisher : Publisher.t;
  write_timeout : float;
  close_flush_timeout : float;
  routes : (string * (string * string)) list;
  input : input_handler option;
  allow_control : bool;
  mutable controller : conn option;
  mutable conns : conn list;
  mutable lifecycles : connection_lifecycle list;
  mutable last_outcome : Tessera.outcome option;
}

let close_connection lifecycle =
  if lifecycle.fd_closed then Lwt.return_unit
  else begin
    lifecycle.fd_closed <- true;
    lifecycle.cleanup ();
    Lwt.catch
      (fun () ->
        (match Lwt_unix.state lifecycle.fd with
        | Lwt_unix.Closed -> ()
        | _ -> Lwt_unix.shutdown lifecycle.fd Unix.SHUTDOWN_ALL);
        Lwt_unix.close lifecycle.fd)
      (fun _exn -> Lwt.return_unit)
  end

let port t = t.port
let token t = t.token
let bootstrap_url t = Printf.sprintf "http://127.0.0.1:%d/?token=%s" t.port t.token
let client_count t = Publisher.client_count t.publisher
let physical_input_allowed t = Option.is_none t.controller

let input_state_message outcome =
  let view = Tessera.Input_state.view (Tessera.outcome_input_state outcome) in
  let mouse_tracking =
    match view.mouse_tracking with
    | Tessera.Input_state.Off -> `Off
    | Tessera.Input_state.X10 -> `X10
    | Tessera.Input_state.Button_event -> `Button_event
    | Tessera.Input_state.Any_event -> `Any_event
  in
  let mouse_encoding =
    match view.mouse_encoding with
    | Tessera.Input_state.Default -> `Default
    | Tessera.Input_state.Utf8 -> `Utf8
    | Tessera.Input_state.Sgr -> `Sgr
    | Tessera.Input_state.Urxvt -> `Urxvt
  in
  let generation =
    Format.asprintf "%a" Tessera.Generation.pp (Tessera.Renderer.generation (Tessera.outcome_snapshot outcome))
  in
  Control.encode_server_message
    (Control.Input_state
       {
         generation;
         application_cursor = view.application_cursor;
         application_keypad = view.application_keypad;
         bracketed_paste = view.bracketed_paste;
         focus_reporting = view.focus_reporting;
         mouse_tracking;
         mouse_encoding;
       })

(* --- websocket connection handler --- *)

let websocket_handler t lifecycle wsd =
  let conn =
    { wake = Lwt_condition.create (); state = `Awaiting_hello; fragment = Idle; closing = false; cleaned_up = false }
  in
  t.conns <- conn :: t.conns;

  let send_text s =
    if not conn.closing then begin
      let bytes = Bytes.of_string s in
      Httpun_ws.Wsd.send_bytes wsd ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes)
    end
  in

  (* Gives an orderly peer a short chance to receive the final control reply and Close frame, then closes
     the descriptor we own.  A write-timeout peer has already demonstrated that it is not draining, so
     that path skips this grace period. *)
  let wait_for_flush () =
    let promise, resolver = Lwt.task () in
    let settled = ref false in
    Httpun_ws.Wsd.flushed wsd (fun () ->
        if not !settled then begin
          settled := true;
          Lwt.wakeup_later resolver ()
        end);
    Lwt.async (fun () ->
        Lwt.bind
          (Lwt.pick [ promise; Lwt_unix.sleep t.close_flush_timeout ])
          (fun () ->
            if not !settled then settled := true;
            close_connection lifecycle))
  in

  (* The terminal path: set [closing] first (synchronously, before anything else runs), so the writer
     task and any *other* [send_text] caller become no-ops from this point on and nothing else can
     interleave into [Wsd] during teardown -- then send at most one message directly (bypassing
     [send_text]'s own [closing] guard, which exists to block everyone *except* this one allowed
     message), then close with an explicit code (bare [Wsd.close] with no [~code] never serialises a
     Close frame onto the wire at all). [close_connection] owns descriptor closure and calls [cleanup]
     exactly once, whether the peer EOF, a write error, or this server-initiated path wins the race. *)
  let terminate ?message ?(flush = true) ~code () =
    if not conn.closing then begin
      conn.closing <- true;
      Option.iter
        (fun s ->
          let bytes = Bytes.of_string s in
          Httpun_ws.Wsd.send_bytes wsd ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes))
        message;
      Httpun_ws.Wsd.close ~code wsd;
      if flush then wait_for_flush () else Lwt.async (fun () -> close_connection lifecycle)
    end
  in

  let error_message message = Control.encode_server_message (Control.Error { id = None; message }) in

  let cleanup () =
    if not conn.cleaned_up then begin
      conn.cleaned_up <- true;
      conn.closing <- true;
      (match conn.state with `Attached client -> Publisher.detach t.publisher client | `Awaiting_hello -> ());
      (match t.controller with Some controller when controller == conn -> t.controller <- None | _ -> ());
      t.conns <- List.filter (fun c -> c != conn) t.conns;
      Lwt_condition.signal conn.wake ()
    end
  in
  lifecycle.cleanup <- cleanup;

  let rec writer_loop () =
    if conn.closing then Lwt.return_unit
    else
      match conn.state with
      | `Awaiting_hello -> Lwt.return_unit
      | `Attached client -> (
          match Publisher.take_one_pending t.publisher client with
          | None -> Lwt.bind (Lwt_condition.wait conn.wake) writer_loop
          | Some json ->
              let settled = ref false in
              let promise, resolver = Lwt.task () in
              (* Wsd.flushed is Faraday.flush, which invokes its
                 callback immediately when the writer is already idle at registration time -- so
                 registering it before this send_bytes would report the *previous* idle state, not
                 this frame's flush, silently disabling the write_timeout bound below for a send that
                 genuinely never completes. Enqueue first, then register flushed, so the callback can
                 only fire once *this* frame has actually drained. *)
              let bytes = Bytes.of_string json in
              Httpun_ws.Wsd.send_bytes wsd ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes);
              Httpun_ws.Wsd.flushed wsd (fun () ->
                  if not !settled then begin
                    settled := true;
                    Lwt.wakeup_later resolver ()
                  end);
              Lwt.bind
                (Lwt.pick
                   [
                     Lwt.map (fun () -> `Flushed) promise; Lwt.map (fun () -> `Timeout) (Lwt_unix.sleep t.write_timeout);
                   ])
                (function
                  | `Flushed -> writer_loop ()
                  | `Timeout ->
                      if not !settled then settled := true;
                      terminate ~flush:false ~code:`Policy_violation ();
                      Lwt.return_unit))
  in

  let handle_complete_text text =
    if not conn.closing then
      match Control.decode_client_message ~max_bytes:max_control_message_bytes text with
      | Error err -> (
          match Err.Error.kind err with
          | `Oversize -> terminate ~code:`Policy_violation ~message:(error_message "oversize control message") ()
          | (`Json _ | `Unknown_schema _ | `Unknown_type _ | `Unknown_version _) as domain_error ->
              terminate ~code:`Protocol_error
                ~message:(error_message (Format.asprintf "%a" Control.pp_error domain_error))
                ())
      | Ok message -> (
          match (conn.state, message) with
          | `Awaiting_hello, Control.Hello { id; target } ->
              let publisher_target =
                match target with Control.Html -> Publisher.Html | Control.Canvas -> Publisher.Canvas
              in
              let client = Publisher.attach t.publisher ~target:publisher_target in
              Option.iter (Publisher.prepend_pending t.publisher client) (Option.map input_state_message t.last_outcome);
              conn.state <- `Attached client;
              send_text
                (Control.encode_server_message
                   (Control.Ready
                      {
                        id;
                        capabilities =
                          { observe = true; input = t.allow_control && Option.is_some t.input; resize = false };
                      }));
              Lwt.async writer_loop
          | ( `Awaiting_hello,
              ( Control.Resync { id }
              | Control.Close { id }
              | Control.Acquire_control { id }
              | Control.Release_control { id }
              | Control.Input { id; _ } ) ) ->
              terminate ~code:`Protocol_error
                ~message:
                  (Control.encode_server_message (Control.Error { id = Some id; message = "hello required first" }))
                ()
          | `Attached _, Control.Hello { id; _ } ->
              terminate ~code:`Protocol_error
                ~message:(Control.encode_server_message (Control.Error { id = Some id; message = "already attached" }))
                ()
          | `Attached _, (Control.Resync { id } | Control.Close { id }) ->
              terminate ~code:`Normal_closure ~message:(Control.encode_server_message (Control.Result { id })) ()
          | `Attached _, Control.Acquire_control { id } -> (
              if (not t.allow_control) || Option.is_none t.input then
                send_text
                  (Control.encode_server_message
                     (Control.Error { id = Some id; message = "browser control is disabled" }))
              else
                match t.controller with
                | None ->
                    t.controller <- Some conn;
                    Option.iter (fun outcome -> send_text (input_state_message outcome)) t.last_outcome;
                    send_text (Control.encode_server_message (Control.Result { id }))
                | Some controller when controller == conn ->
                    send_text (Control.encode_server_message (Control.Result { id }))
                | Some _ ->
                    send_text
                      (Control.encode_server_message
                         (Control.Error { id = Some id; message = "controller lease is held by another client" })))
          | `Attached _, Control.Release_control { id } ->
              if match t.controller with Some controller -> controller == conn | None -> false then begin
                t.controller <- None;
                send_text (Control.encode_server_message (Control.Result { id }))
              end
              else
                send_text
                  (Control.encode_server_message
                     (Control.Error { id = Some id; message = "controller lease required" }))
          | `Attached _, Control.Input { id; bytes } -> (
              if not (match t.controller with Some controller -> controller == conn | None -> false) then
                send_text
                  (Control.encode_server_message
                     (Control.Error { id = Some id; message = "controller lease required" }))
              else
                match t.input with
                | None ->
                    send_text
                      (Control.encode_server_message
                         (Control.Error { id = Some id; message = "browser input is unavailable" }))
                | Some handoff -> (
                    match handoff bytes with
                    | Ok () -> send_text (Control.encode_server_message (Control.Result { id }))
                    | Error message ->
                        send_text (Control.encode_server_message (Control.Error { id = Some id; message })))))
  in

  (* [Payload.schedule_read]'s [on_eof]/[on_read] are each one-shot: "once either of these callbacks
     have been called, they become inactive. The application is responsible for scheduling subsequent
     reads" (httpun's identically-shaped [Body.Reader.schedule_read] doc comment; [Httpun_ws.Payload]
     shares the contract). A payload whose bytes arrive as more than one Faraday chunk therefore never
     reaches [on_eof] at all unless [on_read] re-schedules -- this loops until the payload actually
     reports [`Close] (draining it, not merely peeking at its first chunk). *)
  let rec drain_payload payload ~on_read ~on_eof =
    Httpun_ws.Payload.schedule_read payload ~on_eof ~on_read:(fun bs ~off ~len ->
        on_read bs ~off ~len;
        drain_payload payload ~on_read ~on_eof)
  in

  let accumulate buf bs ~off ~len =
    if Buffer.length buf + len > max_control_message_bytes then `Oversize
    else begin
      Buffer.add_string buf (Bigstringaf.substring bs ~off ~len);
      `Ok
    end
  in

  let handle_non_control opcode ~is_fin payload =
    match (conn.fragment, opcode) with
    | Idle, `Continuation ->
        terminate ~code:`Protocol_error ~message:(error_message "continuation with no prior text") ()
    | In_text _, `Text ->
        terminate ~code:`Protocol_error ~message:(error_message "text frame while one is unfinished") ()
    | (Idle | In_text _), `Binary ->
        terminate ~code:`Protocol_error ~message:(error_message "binary frames are not supported") ()
    | Idle, `Text | In_text _, `Continuation ->
        let buf = match conn.fragment with In_text buf -> buf | Idle -> Buffer.create 256 in
        let oversized = ref false in
        drain_payload payload
          ~on_eof:(fun () ->
            if not !oversized then
              if is_fin then begin
                conn.fragment <- Idle;
                handle_complete_text (Buffer.contents buf)
              end
              else conn.fragment <- In_text buf)
          ~on_read:(fun bs ~off ~len ->
            if not !oversized then
              match accumulate buf bs ~off ~len with
              | `Ok -> ()
              | `Oversize ->
                  oversized := true;
                  terminate ~code:`Policy_violation ~message:(error_message "oversize control message") ())
  in

  let handle_close_payload bytes =
    let length = String.length bytes in
    if length = 0 then terminate ~code:`Normal_closure ()
    else if length = 1 then terminate ~code:`Protocol_error ()
    else
      let code = (Char.code bytes.[0] lsl 8) lor Char.code bytes.[1] in
      let reason = String.sub bytes 2 (length - 2) in
      if close_code_allowed code && valid_utf8 reason then terminate ~code:(`Other code) ()
      else terminate ~code:`Protocol_error ()
  in

  let frame ~opcode ~is_fin ~len payload =
    match opcode with
    | `Ping ->
        if (not is_fin) || len > 125 then terminate ~code:`Protocol_error ()
        else
          let buf = Buffer.create len in
          drain_payload payload
            ~on_eof:(fun () ->
              if Buffer.length buf = 0 then Httpun_ws.Wsd.send_pong wsd
              else
                let application_data = Buffer.contents buf in
                let buffer = Bigstringaf.of_string ~off:0 ~len:(String.length application_data) application_data in
                Httpun_ws.Wsd.send_pong wsd
                  ~application_data:{ Httpun.IOVec.buffer; off = 0; len = String.length application_data })
            ~on_read:(fun bs ~off ~len -> Buffer.add_string buf (Bigstringaf.substring bs ~off ~len))
    | `Pong ->
        if (not is_fin) || len > 125 then terminate ~code:`Protocol_error ()
        else drain_payload payload ~on_eof:ignore ~on_read:(fun _bs ~off:_ ~len:_ -> ())
    | `Connection_close ->
        if (not is_fin) || len > 125 then terminate ~code:`Protocol_error ()
        else
          let buf = Buffer.create len in
          drain_payload payload
            ~on_eof:(fun () -> handle_close_payload (Buffer.contents buf))
            ~on_read:(fun bs ~off ~len -> Buffer.add_string buf (Bigstringaf.substring bs ~off ~len))
    | (`Text | `Binary | `Continuation) as non_control -> handle_non_control non_control ~is_fin payload
    | `Other _ -> terminate ~code:`Protocol_error ~message:(error_message "reserved opcode") ()
  in

  let eof ?error:_ () = cleanup () in

  { Httpun_ws.Websocket_connection.frame; eof }

(* --- HTTP request handler (static routes + the /session upgrade) --- *)

(* [content-length] is set explicitly on every response: without it (and with no [Connection: close]),
   an HTTP/1.1 keep-alive client has no way to know where the body ends -- it is left waiting
   indefinitely for either more bytes or a connection close, neither of which come, since httpun does
   not infer a length from what [respond_with_string] was actually given. Verified against a real
   browser and a plain Node HTTP client both hanging on `page.goto`/`res.on('end', ...)` without this. *)
let respond_text reqd status body =
  Reqd.respond_with_string reqd
    (Response.create
       ~headers:
         (Headers.of_list
            [ ("content-type", "text/plain; charset=utf-8"); ("content-length", string_of_int (String.length body)) ])
       status)
    body

let respond_asset reqd (content_type, body) =
  Reqd.respond_with_string reqd
    (Response.create
       ~headers:
         (Headers.of_list [ ("content-type", content_type); ("content-length", string_of_int (String.length body)) ])
       `OK)
    body

let request_handler t lifecycle _addr (gluten_reqd : Reqd.t Gluten.reqd) =
  let { Gluten.Reqd.reqd; upgrade } = gluten_reqd in
  let request = Reqd.request reqd in
  let path, query = split_target request.Request.target in
  match (request.Request.meth, path) with
  | `GET, "/session" ->
      let supplied_token = Option.value ~default:"" (query_param query "token") in
      let origin_ok =
        match Headers.get request.Request.headers "origin" with
        | None -> true
        | Some origin -> String.equal origin (Printf.sprintf "http://127.0.0.1:%d" t.port)
      in
      if (not origin_ok) || not (constant_time_equal supplied_token t.token) then
        respond_text reqd `Forbidden "forbidden"
      else begin
        let upgrade_handler () =
          let ws_conn = Httpun_ws.Server_connection.create_websocket (fun wsd -> websocket_handler t lifecycle wsd) in
          upgrade (Gluten.make (module Httpun_ws.Server_connection) ws_conn)
        in
        match Httpun_ws.Handshake.respond_with_upgrade ~sha1 reqd upgrade_handler with
        | Ok () -> ()
        | Error message -> respond_text reqd `Bad_request message
      end
  | `GET, path -> (
      match List.assoc_opt path t.routes with
      | Some asset -> respond_asset reqd asset
      | None -> respond_text reqd `Not_found "not found")
  | _, path when String.equal path "/session" || List.mem_assoc path t.routes ->
      respond_text reqd `Method_not_allowed "method not allowed"
  | _ -> respond_text reqd `Not_found "not found"

let error_handler _addr ?request:_ (error : Reqd.error) handle =
  let message =
    match error with
    | `Exn exn -> Printexc.to_string exn
    | (`Bad_request | `Bad_gateway | `Internal_server_error) as status -> Status.to_string status
  in
  let body = handle Headers.empty in
  Body.Writer.write_string body message;
  Body.Writer.close body

(* --- lifecycle --- *)

let backlog = 16
let ignore_unix_error thunk = try thunk () with Unix.Unix_error (_, _, _) -> ()
let env_int name = match Sys.getenv_opt name with None -> None | Some s -> int_of_string_opt s

let create ?port ?token ?ready_file ?input ?(allow_control = false) ~max_pending_bytes ~write_timeout
    ~close_flush_timeout () =
  let requested_port = match port with Some p -> Some p | None -> env_int "TESSERA_PROXY_WEB_PORT" in
  let requested_token = match token with Some t -> Some t | None -> Sys.getenv_opt "TESSERA_PROXY_WEB_TOKEN" in
  let ready_file = match ready_file with Some f -> Some f | None -> Sys.getenv_opt "TESSERA_PROXY_WEB_READY_FILE" in
  let* actual_token = match requested_token with Some tok -> Ok tok | None -> generate_token () in
  let* fd =
    E.protect ~pos:__POS__
      ~catch:(function Unix.Unix_error (code, _, _) -> Some (`Socket_failed code) | _ -> None)
      (fun () -> Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0)
  in
  let* () =
    E.protect ~pos:__POS__
      ~catch:(function
        | Unix.Unix_error (code, _, _) ->
            ignore_unix_error (fun () -> Unix.close fd);
            Some (`Bind_failed code)
        | _ -> None)
      (fun () ->
        Unix.setsockopt fd Unix.SO_REUSEADDR true;
        Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, Option.value ~default:0 requested_port)))
  in
  let* () =
    E.protect ~pos:__POS__
      ~catch:(function
        | Unix.Unix_error (code, _, _) ->
            ignore_unix_error (fun () -> Unix.close fd);
            Some (`Listen_failed code)
        | _ -> None)
      (fun () ->
        Unix.listen fd backlog;
        Unix.set_nonblock fd)
  in
  let bound_port = match Unix.getsockname fd with Unix.ADDR_INET (_, p) -> p | Unix.ADDR_UNIX _ -> assert false in
  let t =
    {
      listen_fd = fd;
      listen_lwt = Lwt_unix.of_unix_file_descr ~blocking:false fd;
      port = bound_port;
      token = actual_token;
      publisher = Publisher.create ~max_pending_bytes;
      write_timeout;
      close_flush_timeout;
      routes = List.map (fun (route, content_type, body) -> (route, (content_type, body))) Web_assets.routes;
      input;
      allow_control;
      controller = None;
      conns = [];
      lifecycles = [];
      last_outcome = None;
    }
  in
  Option.iter
    (fun path ->
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc (bootstrap_url t)))
    ready_file;
  Ok t

let note_outcome t outcome =
  t.last_outcome <- Some outcome;
  (match Publisher.note_outcome t.publisher ~before:(fun _target -> input_state_message outcome) outcome with
  | Ok () -> ()
  | Error err ->
      Printf.eprintf "tessera-proxy: web publisher: %s\n%!"
        (Format.asprintf "%a" Publisher.pp_error (Err.Error.kind err)));
  List.iter
    (fun conn -> match conn.state with `Attached _ -> Lwt_condition.signal conn.wake () | `Awaiting_hello -> ())
    t.conns

(* A small Lwt driver for [Gluten.Server].  It is deliberately local rather than using
   [Httpun_lwt_unix.Server.create_connection_handler]: the latter hides the accepted descriptor and its
   read loop continues after EOF.  Here EOF is terminal, invokes the WebSocket runtime once, shuts down
   its sibling writer, and then runs [close_connection], which detaches the publisher client. *)
let handler t addr fd =
  let lifecycle = { fd; fd_closed = false; cleanup = (fun () -> ()) } in
  t.lifecycles <- lifecycle :: t.lifecycles;
  let connection =
    Gluten.Server.create_upgradable
      ~protocol:(module Httpun.Server_connection)
      ~create:(Httpun.Server_connection.create ~error_handler:(error_handler addr))
      (request_handler t lifecycle addr)
  in
  let read_buffer = Gluten.Buffer.create Httpun.Config.default.read_buffer_size in
  let await_yield register =
    let promise, resolver = Lwt.wait () in
    register (fun () -> if Lwt.is_sleeping promise then Lwt.wakeup_later resolver ());
    promise
  in
  let read_once () =
    let promise, resolver = Lwt.wait () in
    Gluten.Buffer.put
      ~f:(fun buffer ~off ~len wake ->
        let read = Lwt_bytes.read fd buffer off len in
        Lwt.on_success read wake;
        Lwt.on_failure read (fun exn -> if Lwt.is_sleeping promise then Lwt.wakeup_later_exn resolver exn))
      read_buffer
      (fun read -> if Lwt.is_sleeping promise then Lwt.wakeup_later resolver read);
    promise
  in
  let rec read_loop () =
    match Gluten.Server.next_read_operation connection with
    | `Read ->
        Lwt.catch
          (fun () ->
            Lwt.bind (read_once ()) (fun (read : int) ->
                if read = 0 then Lwt.fail End_of_file
                else begin
                  ignore (Gluten.Buffer.get read_buffer ~f:(Gluten.Server.read connection));
                  read_loop ()
                end))
          (function
            | End_of_file ->
                ignore (Gluten.Buffer.get read_buffer ~f:(Gluten.Server.read_eof connection));
                Gluten.Server.shutdown connection;
                Lwt.return_unit
            | exn ->
                Gluten.Server.report_exn connection exn;
                Gluten.Server.shutdown connection;
                Lwt.return_unit)
    | `Yield -> Lwt.bind (await_yield (Gluten.Server.yield_reader connection)) read_loop
    | `Close ->
        Gluten.Server.shutdown connection;
        Lwt.return_unit
  in
  let rec write_loop () =
    match Gluten.Server.next_write_operation connection with
    | `Write io_vectors ->
        Lwt.catch
          (fun () ->
            Lwt.bind (Faraday_lwt_unix.writev_of_fd fd io_vectors) (fun result ->
                Gluten.Server.report_write_result connection result;
                match result with
                | `Ok _ -> write_loop ()
                | `Closed ->
                    Gluten.Server.shutdown connection;
                    Lwt.return_unit))
          (fun exn ->
            Gluten.Server.report_exn connection exn;
            Gluten.Server.shutdown connection;
            Lwt.return_unit)
    | `Yield -> Lwt.bind (await_yield (Gluten.Server.yield_writer connection)) write_loop
    | `Close _ -> Lwt.return_unit
  in
  Lwt.finalize
    (fun () -> Lwt.join [ read_loop (); write_loop () ])
    (fun () ->
      t.lifecycles <- List.filter (fun candidate -> candidate != lifecycle) t.lifecycles;
      close_connection lifecycle)

let run t ~stop =
  let rec loop () =
    Lwt.bind
      (Lwt.pick [ Lwt.map (fun () -> `Readable) (Lwt_unix.wait_read t.listen_lwt); Lwt.map (fun () -> `Stop) stop ])
      (function
        | `Stop -> Lwt.return_unit
        | `Readable ->
            let rec accept_all () =
              match Unix.accept ~cloexec:true t.listen_fd with
              | fd, addr ->
                  Unix.set_nonblock fd;
                  Lwt.async (fun () -> handler t addr (Lwt_unix.of_unix_file_descr ~blocking:false fd));
                  accept_all ()
              | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> accept_all ()
            in
            accept_all ();
            loop ())
  in
  loop ()

let close t =
  Lwt_main.run
    (Lwt.join
       [
         Lwt.catch (fun () -> Lwt_unix.close t.listen_lwt) (fun _exn -> Lwt.return_unit);
         Lwt.join (List.map close_connection t.lifecycles);
       ])
