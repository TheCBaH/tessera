module Foundation = Tessera_foundation

let ( let* ) = Result.bind

type read_result = Chunk of Tessera.outcome | Eof of Tessera.outcome

type error =
  [ `Invalid_count of Foundation.UInt.error
  | `Invalid_value of Foundation.Types.error
  | `Read_failed of exn
  | `Session of Tessera.Session.error ]

let pp_error ppf = function
  | `Invalid_count error -> Format.fprintf ppf "invalid-count(%a)" Foundation.UInt.pp_error error
  | `Invalid_value error -> Format.fprintf ppf "invalid-value(%a)" Foundation.Types.pp_error error
  | `Read_failed exn -> Format.fprintf ppf "read-failed(%s)" (Printexc.to_string exn)
  | `Session error -> Format.fprintf ppf "session(%a)" Tessera.Session.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

type t = { mutable session : Tessera.session; lock : unit Async.Throttle.Sequencer.t }

let create ~lineage_id ~policy ~size =
  { session = Tessera.initial ~lineage_id ~policy ~size; lock = Async.Throttle.Sequencer.create () }

(* [f] is a pure computation; the sequencer runs it exclusively for its (brief) synchronous extent, never across a
   pending Async read, so a concurrent [resize] job queued behind it is never stuck behind an in-flight read. *)
let with_lock t f = Async.Throttle.enqueue t.lock (fun () -> Async.Deferred.return (f ()))

(* Callers hold [t.lock] for the duration of these two: they read the current session, ingest, and store the
   successor session as one atomic step, so a concurrent [resize] and [run] read never observe or advance from the
   same session concurrently. *)
let ingest_locked t input =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Session error) (Tessera.ingest t.session input) in
  t.session <- Tessera.session outcome;
  Ok outcome

let finish_locked t =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Session error) (Tessera.finish t.session) in
  t.session <- Tessera.session outcome;
  Ok outcome

let resize t ~columns ~rows =
  with_lock t (fun () ->
      let* columns = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int columns) in
      let* rows = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int rows) in
      let* size =
        E.map_error ~pos:__POS__ (fun error -> `Invalid_value error) (Foundation.Types.Size.make ~columns ~rows)
      in
      ingest_locked t (Tessera.Out_of_band (Tessera.Resize size)))

let build_slice buffer bytes_read =
  let* off = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int 0) in
  let* len = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int bytes_read) in
  E.map_error ~pos:__POS__ (fun error -> `Invalid_value error) (Foundation.Types.slice buffer ~off ~len)

(* Mirrors Tessera_unix.Unix_adapter.read_step and Tessera_lwt.Lwt_adapter.read_step: the read itself is awaited
   outside the lock, so a concurrent [resize] job is never stuck behind a read that has not resolved; only the brief
   session mutation that follows a completed read is serialised. Async.Reader.read can send an exception to the
   ambient monitor rather than return it, so the read runs under Monitor.try_with to keep failures inside the typed
   result instead. *)
let read_step t reader buffer =
  Async.Deferred.bind
    (Async.Monitor.try_with ~extract_exn:true (fun () -> Async.Reader.read reader buffer))
    ~f:(function
      | Error exn -> Async.Deferred.return (E.fail ~pos:__POS__ (`Read_failed exn))
      | Ok `Eof ->
          with_lock t (fun () ->
              let* outcome = finish_locked t in
              Ok (Eof outcome))
      | Ok (`Ok bytes_read) ->
          with_lock t (fun () ->
              let* chunk = build_slice buffer bytes_read in
              let* outcome = ingest_locked t (Tessera.Bytes chunk) in
              Ok (Chunk outcome)))

let run t reader ~read_buffer_bytes ~on_outcome ~on_error =
  let buffer = Bytes.create read_buffer_bytes in
  let rec loop () =
    Async.Deferred.bind (read_step t reader buffer) ~f:(function
      | Error error ->
          on_error error;
          Async.Deferred.return ()
      | Ok (Chunk outcome) ->
          on_outcome outcome;
          loop ()
      | Ok (Eof outcome) ->
          on_outcome outcome;
          Async.Deferred.return ())
  in
  loop ()
