module Observer = Tessera_proxy_observer
module Protocol = Tessera_proxy_protocol.Frame

type error =
  [ `Bind_failed of Unix.error
  | `Directory_failed of Unix.error
  | `Listen_failed of Unix.error
  | `Socket_failed of Unix.error ]

let pp_error ppf = function
  | `Bind_failed code -> Format.fprintf ppf "bind-failed(%s)" (Unix.error_message code)
  | `Directory_failed code -> Format.fprintf ppf "directory-failed(%s)" (Unix.error_message code)
  | `Listen_failed code -> Format.fprintf ppf "listen-failed(%s)" (Unix.error_message code)
  | `Socket_failed code -> Format.fprintf ppf "socket-failed(%s)" (Unix.error_message code)

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let ( let* ) = Result.bind

(* A client's read-only stream position, distinguishing "never sent anything yet" (a brand-new connection, no [Gap]
   needed) from "was streaming, now needs to resynchronise" (a [Gap] frame must precede the fresh snapshot) from the
   ordinary flowing state. *)
type client_state = Fresh | Resyncing of { skipped : int } | Streaming of Observer.Ring.cursor
type client = { fd : Unix.file_descr; pending : Buffer.t; mutable state : client_state }

type t = {
  listen_fd : Unix.file_descr;
  socket_path : string;
  ring : Observer.Ring.t;
  authority : Protocol.Authority.t;
  max_pending_bytes : int;
  mutable clients : client list;
  mutable latest_outcome : Tessera.outcome option;
}

let backlog = 16
let ignore_unix_error thunk = try thunk () with Unix.Unix_error (_, _, _) -> ()

let create ~socket_path ~ring ~policy ~max_pending_bytes =
  let directory = Filename.dirname socket_path in
  let* () =
    if Sys.file_exists directory then Ok ()
    else
      E.protect ~pos:__POS__
        ~catch:(function Unix.Unix_error (code, _, _) -> Some (`Directory_failed code) | _ -> None)
        (fun () -> Unix.mkdir directory 0o700)
  in
  let* fd =
    E.protect ~pos:__POS__
      ~catch:(function Unix.Unix_error (code, _, _) -> Some (`Socket_failed code) | _ -> None)
      (fun () -> Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0)
  in
  ignore_unix_error (fun () -> Unix.unlink socket_path);
  (* Every branch below has already allocated [fd]: a failure here must close it before returning,
     or a caller that retries {!create} (e.g. across proxy restarts) leaks one descriptor per
     failed attempt. *)
  let* () =
    E.protect ~pos:__POS__
      ~catch:(function
        | Unix.Unix_error (code, _, _) ->
            ignore_unix_error (fun () -> Unix.close fd);
            Some (`Bind_failed code)
        | _ -> None)
      (fun () ->
        Unix.bind fd (Unix.ADDR_UNIX socket_path);
        Unix.chmod socket_path 0o600)
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
  Ok
    {
      listen_fd = fd;
      socket_path;
      ring;
      authority = Protocol.Authority.make ~policy;
      max_pending_bytes;
      clients = [];
      latest_outcome = None;
    }

let listen_fd t = t.listen_fd
let read_fds t = List.map (fun client -> client.fd) t.clients

let write_fds t =
  List.filter_map (fun client -> if Buffer.length client.pending > 0 then Some client.fd else None) t.clients

let client_count t = List.length t.clients

let remove_client t fd =
  (match List.find_opt (fun client -> client.fd = fd) t.clients with
  | None -> ()
  | Some client -> ignore_unix_error (fun () -> Unix.close client.fd));
  t.clients <- List.filter (fun client -> client.fd <> fd) t.clients

let send_snapshot t client outcome =
  let position = Observer.Ring.cursor_to_int (Observer.Ring.cursor t.ring) in
  let snapshot = Protocol.Snapshot.of_outcome ~position outcome in
  Protocol.encode client.pending (Protocol.Authoritative_snapshot (t.authority, snapshot));
  client.state <- Streaming (Observer.Ring.cursor t.ring)

(* Runs once per client per {!drain}/{!note_outcome}/{!accept} call: advances a [Streaming] client as far as the ring
   and [max_pending_bytes] allow, resolves a [Fresh]/[Resyncing] client into [Streaming] as soon as an outcome is on
   hand, and never writes a single byte to the socket itself -- {!flush} does that, so this function can never
   block. *)
let rec advance t client =
  match client.state with
  | Fresh -> ( match t.latest_outcome with None -> () | Some outcome -> send_snapshot t client outcome)
  | Resyncing { skipped } -> (
      match t.latest_outcome with
      | None -> ()
      | Some outcome ->
          Protocol.encode client.pending
            (Protocol.Gap { skipped; resume = Observer.Ring.cursor_to_int (Observer.Ring.cursor t.ring) });
          send_snapshot t client outcome)
  | Streaming cursor -> (
      match Observer.Ring.read t.ring cursor with
      | None -> ()
      | Some (Observer.Ring.Gap { skipped; resume = _ }) ->
          Buffer.clear client.pending;
          client.state <- Resyncing { skipped };
          advance t client
      | Some (Observer.Ring.Record (record, next_cursor)) ->
          Protocol.encode client.pending (Protocol.of_record record);
          if Buffer.length client.pending > t.max_pending_bytes then (
            let skipped =
              Observer.Ring.cursor_to_int (Observer.Ring.cursor t.ring) - Observer.Ring.cursor_to_int cursor
            in
            Buffer.clear client.pending;
            client.state <- Resyncing { skipped };
            advance t client)
          else (
            client.state <- Streaming next_cursor;
            advance t client))

(* Flushes as much of [client.pending] as one non-blocking write accepts. A hard failure (anything but
   [EAGAIN]/[EWOULDBLOCK]/[EINTR] -- most commonly [EPIPE]/[ECONNRESET] once the peer has gone away) removes the
   client rather than leaving a dead descriptor accumulating an ever-growing buffer forever. *)
let flush t client =
  let pending_length = Buffer.length client.pending in
  if pending_length > 0 then
    match Unix.write client.fd (Buffer.to_bytes client.pending) 0 pending_length with
    | written ->
        let leftover = Buffer.to_bytes client.pending in
        Buffer.clear client.pending;
        if written < pending_length then Buffer.add_subbytes client.pending leftover written (pending_length - written)
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> ()
    | exception Unix.Unix_error (_, _, _) -> remove_client t client.fd

let service_all t =
  (* [advance]/[flush] can call {!remove_client}, which mutates [t.clients]; iterate over a snapshot list so removal
     during the walk never skips or revisits an entry. *)
  List.iter
    (fun client ->
      if List.memq client t.clients then (
        advance t client;
        flush t client))
    t.clients

let note_outcome t outcome =
  t.latest_outcome <- Some outcome;
  service_all t

let drain t = service_all t

let accept t =
  let rec loop () =
    match Unix.accept ~cloexec:true t.listen_fd with
    | fd, _ ->
        Unix.set_nonblock fd;
        let client = { fd; pending = Buffer.create 256; state = Fresh } in
        Protocol.write_preamble client.pending;
        t.clients <- client :: t.clients;
        advance t client;
        flush t client;
        loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let on_readable t fd =
  if List.exists (fun client -> client.fd = fd) t.clients then
    let buffer = Bytes.create 256 in
    (* release one: a read-only client sending bytes at all is a protocol violation; discard them without acting on
       them, and treat only EOF/a hard read error as this client going away. *)
    let rec drain_readable () =
      match Unix.read fd buffer 0 (Bytes.length buffer) with
      | 0 -> remove_client t fd
      | _ -> drain_readable ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain_readable ()
      | exception Unix.Unix_error (_, _, _) -> remove_client t fd
    in
    drain_readable ()

let on_writable t fd =
  match List.find_opt (fun client -> client.fd = fd) t.clients with
  | None -> ()
  | Some client ->
      flush t client;
      if List.memq client t.clients then (
        advance t client;
        flush t client)

let close t =
  ignore_unix_error (fun () -> Unix.close t.listen_fd);
  List.iter (fun client -> ignore_unix_error (fun () -> Unix.close client.fd)) t.clients;
  t.clients <- [];
  ignore_unix_error (fun () -> Unix.unlink t.socket_path)
