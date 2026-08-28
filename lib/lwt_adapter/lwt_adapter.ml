module Foundation = Tessera_foundation

let ( let* ) = Result.bind

type read_result = Chunk of Tessera.outcome | Eof of Tessera.outcome

type error =
  [ `Invalid_count of Foundation.UInt.error
  | `Invalid_value of Foundation.Types.error
  | `Read_failed of Unix.error * string * string
  | `Session of Tessera.Session.error ]

let pp_error ppf = function
  | `Invalid_count error -> Format.fprintf ppf "invalid-count(%a)" Foundation.UInt.pp_error error
  | `Invalid_value error -> Format.fprintf ppf "invalid-value(%a)" Foundation.Types.pp_error error
  | `Read_failed (code, function_name, argument) ->
      Format.fprintf ppf "read-failed(%s(%s): %s)" function_name argument (Unix.error_message code)
  | `Session error -> Format.fprintf ppf "session(%a)" Tessera.Session.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

type t = { mutable session : Tessera.session; lock : Lwt_mutex.t }

let create ~lineage_id ~policy ~size =
  { session = Tessera.initial ~lineage_id ~policy ~size; lock = Lwt_mutex.create () }

(* [f] is a pure computation; the lock is held only for its (brief) synchronous extent, never across a pending Lwt
   read, so a concurrent [resize] promise queued behind this lock is never stuck behind an in-flight read. *)
let with_lock t f = Lwt_mutex.with_lock t.lock (fun () -> Lwt.return (f ()))

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

let ingest_slice t slice = with_lock t (fun () -> ingest_locked t (Tessera.Bytes slice))
let finish t = with_lock t (fun () -> finish_locked t)

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

(* Mirrors Tessera_unix.Unix_adapter.read_step: the read itself is awaited outside the lock, so a concurrent [resize]
   promise is never stuck behind a read that has not resolved; only the brief session mutation that follows a
   completed read is serialised. *)
let read_step t descriptor buffer =
  Lwt.bind
    (Lwt.catch
       (fun () -> Lwt.map Result.ok (Lwt_unix.read descriptor buffer 0 (Bytes.length buffer)))
       (function
         | Unix.Unix_error (code, function_name, argument) ->
             Lwt.return (E.fail ~pos:__POS__ (`Read_failed (code, function_name, argument)))
         | exn -> Lwt.reraise exn))
    (function
      | Error _ as error -> Lwt.return error
      | Ok bytes_read -> (
          if bytes_read = 0 then Lwt.map (Result.map (fun outcome -> Eof outcome)) (finish t)
          else
            match build_slice buffer bytes_read with
            | Error _ as error -> Lwt.return error
            | Ok chunk -> Lwt.map (Result.map (fun outcome -> Chunk outcome)) (ingest_slice t chunk)))

let run t descriptor ~read_buffer_bytes ~on_outcome ~on_error =
  let buffer = Bytes.create read_buffer_bytes in
  let rec loop () =
    Lwt.bind (read_step t descriptor buffer) (function
      | Error error ->
          on_error error;
          Lwt.return_unit
      | Ok (Chunk outcome) ->
          on_outcome outcome;
          loop ()
      | Ok (Eof outcome) ->
          on_outcome outcome;
          Lwt.return_unit)
  in
  loop ()
