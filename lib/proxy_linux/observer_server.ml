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

type client = {
  fd : Lwt_unix.file_descr;
  pending : Buffer.t;
  wake : unit Lwt_condition.t;  (** Signalled whenever [pending] gains bytes, so the writer task wakes and drains it. *)
  mutable state : client_state;
  mutable alive : bool;
}

type t = {
  listen_fd : Unix.file_descr;
  listen_lwt : Lwt_unix.file_descr;
  socket_path : string;
  ring : Observer.Ring.t;
  authority : Protocol.Authority.t;
  max_pending_bytes : int;
  mutable clients : client list;
  mutable latest_outcome : Tessera.outcome option;
}

let backlog = 16
let ignore_unix_error thunk = try thunk () with Unix.Unix_error (_, _, _) -> ()

(* Catches everything, not just the specific exceptions a caller happens to anticipate: a client's fd can be closed
   from several independent places (this client's own reader task, its writer task, or {!close} tearing down every
   client at once), so a "the other side got there first and this operation now targets an already-closed channel"
   race is a normal outcome here, not a bug to enumerate exceptions for. *)
let close_client_fd client = Lwt.catch (fun () -> Lwt_unix.close client.fd) (fun _exn -> Lwt.return_unit)

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
      listen_lwt = Lwt_unix.of_unix_file_descr ~blocking:false fd;
      socket_path;
      ring;
      authority = Protocol.Authority.make ~policy;
      max_pending_bytes;
      clients = [];
      latest_outcome = None;
    }

let client_count t = List.length t.clients

(* Only flips [alive]/unlists the client and wakes its writer -- it never itself awaits {!close_client_fd}, so every
   caller (the reader task, the writer task, or {!close}) closes the descriptor as part of its own already-running
   async chain instead of a detached fire-and-forget task, which could otherwise be abandoned before ever getting a
   turn to run (nothing would then be driving the scheduler to complete it). *)
let remove_client t client =
  if client.alive then (
    client.alive <- false;
    t.clients <- List.filter (fun c -> c != client) t.clients;
    Lwt_condition.signal client.wake ())

let send_snapshot t client outcome =
  let position = Observer.Ring.cursor_to_int (Observer.Ring.cursor t.ring) in
  let snapshot = Protocol.Snapshot.of_outcome ~position outcome in
  Protocol.encode client.pending (Protocol.Authoritative_snapshot (t.authority, snapshot));
  client.state <- Streaming (Observer.Ring.cursor t.ring)

(* Runs once per client per {!drain}/{!note_outcome}/{!accept} call: advances a [Streaming] client as far as the ring
   and [max_pending_bytes] allow, resolves a [Fresh]/[Resyncing] client into [Streaming] as soon as an outcome is on
   hand, and never writes a single byte to the socket itself -- the client's own writer task (woken via [wake]) does
   that, so this function can never block. Deliberately never signals [wake] itself: {!Lwt_condition.signal} runs its
   waiter synchronously, and a signal from partway through this recursion would let the writer task drain
   [client.pending] out from under the very byte-count check below it, defeating the whole [max_pending_bytes] policy
   (a burst would then observe many small flushes instead of one bounded batch followed by a gap). {!service_all}
   signals once, after this settles. *)
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

let service_all t =
  List.iter
    (fun client ->
      advance t client;
      if Buffer.length client.pending > 0 then Lwt_condition.signal client.wake ())
    t.clients

let note_outcome t outcome =
  t.latest_outcome <- Some outcome;
  service_all t

let drain t = service_all t

(* One per connected client: drains [client.pending] via non-blocking {!Lwt_unix.write}, waiting on {!wake} whenever
   there is nothing to send. A hard failure (anything but the transient conditions {!Lwt_unix.write} already retries
   internally -- most commonly [EPIPE]/[ECONNRESET] once the peer has gone away, or a race against another task
   already closing this same client) removes the client rather than leaving a dead descriptor accumulating an
   ever-growing buffer forever. *)
let rec writer_loop t client =
  if not client.alive then Lwt.return_unit
  else if Buffer.length client.pending = 0 then
    Lwt.bind (Lwt_condition.wait client.wake) (fun () -> writer_loop t client)
  else
    let chunk = Buffer.to_bytes client.pending in
    Buffer.clear client.pending;
    let rec write_all offset =
      if offset < Bytes.length chunk then
        Lwt.bind
          (Lwt_unix.write client.fd chunk offset (Bytes.length chunk - offset))
          (fun written -> write_all (offset + written))
      else Lwt.return_unit
    in
    Lwt.bind
      (Lwt.catch (fun () -> Lwt.map (fun () -> true) (write_all 0)) (fun _exn -> Lwt.return_false))
      (fun ok ->
        if ok then writer_loop t client
        else (
          remove_client t client;
          close_client_fd client))

(* release one: a read-only client sending bytes at all is a protocol violation; discard them without acting on them,
   and treat only EOF/a hard read error (including the same close race {!writer_loop} guards against) as this client
   going away. *)
let reader_loop t client =
  let buffer = Bytes.create 256 in
  let rec loop () =
    if not client.alive then Lwt.return_unit
    else
      Lwt.bind
        (Lwt.catch
           (fun () -> Lwt.map Result.ok (Lwt_unix.read client.fd buffer 0 (Bytes.length buffer)))
           (fun _exn -> Lwt.return (Error ())))
        (function
          | Error () | Ok 0 ->
              remove_client t client;
              close_client_fd client
          | Ok _ -> loop ())
  in
  loop ()

let accept t =
  let rec loop () =
    match Unix.accept ~cloexec:true t.listen_fd with
    | fd, _ ->
        Unix.set_nonblock fd;
        let client =
          {
            fd = Lwt_unix.of_unix_file_descr ~blocking:false fd;
            pending = Buffer.create 256;
            wake = Lwt_condition.create ();
            state = Fresh;
            alive = true;
          }
        in
        Protocol.write_preamble client.pending;
        t.clients <- client :: t.clients;
        advance t client;
        if Buffer.length client.pending > 0 then Lwt_condition.signal client.wake ();
        Lwt.async (fun () -> writer_loop t client);
        Lwt.async (fun () -> reader_loop t client);
        loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

(* Watches the listen socket and accepts every pending connection until [stop] resolves -- the composition root
   signals that once the proxy's relay has ended. Mirrors {!Session.run_resize_loop}'s stop-signal shape rather than
   an EOF of its own, since a listen socket has no EOF. *)
let rec run t ~stop =
  Lwt.bind
    (Lwt.pick [ Lwt.map (fun () -> `Readable) (Lwt_unix.wait_read t.listen_lwt); Lwt.map (fun () -> `Stop) stop ])
    (function
      | `Stop -> Lwt.return_unit
      | `Readable ->
          accept t;
          run t ~stop)

let close t =
  Lwt_main.run
    (let clients = t.clients in
     t.clients <- [];
     List.iter (fun client -> client.alive <- false) clients;
     Lwt.bind
       (Lwt.join (List.map close_client_fd clients))
       (fun () ->
         Lwt.bind
           (Lwt.catch (fun () -> Lwt_unix.close t.listen_lwt) (fun _exn -> Lwt.return_unit))
           (fun () ->
             ignore_unix_error (fun () -> Unix.unlink t.socket_path);
             Lwt.return_unit)))
