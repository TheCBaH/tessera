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

type t = { mutable session : Tessera.session; lock : Mutex.t }

let create ~lineage_id ~policy ~size = { session = Tessera.initial ~lineage_id ~policy ~size; lock = Mutex.create () }

let with_lock t f =
  Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.lock) f

(* Callers hold [t.lock] for the duration of these two: they read the current session, ingest, and
   store the successor session as one atomic step, so a concurrent [resize] and [run] read never
   observe or advance from the same session concurrently. *)
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

(* The blocking read itself happens outside the lock, so a concurrent [resize] on another thread
   (e.g. driven by a signal-safe handoff) is never stuck waiting behind a read that may not return
   for a long time; only the brief session mutation that follows a completed read is serialised. *)
let read_step t descriptor buffer =
  let* bytes_read =
    E.protect ~pos:__POS__
      ~catch:(function
        | Unix.Unix_error (code, function_name, argument) -> Some (`Read_failed (code, function_name, argument))
        | _ -> None)
      (fun () -> Unix.read descriptor buffer 0 (Bytes.length buffer))
  in
  with_lock t (fun () ->
      if bytes_read = 0 then
        let* outcome = finish_locked t in
        Ok (Eof outcome)
      else
        let* chunk = build_slice buffer bytes_read in
        let* outcome = ingest_locked t (Tessera.Bytes chunk) in
        Ok (Chunk outcome))

let run t descriptor ~read_buffer_bytes ~on_outcome ~on_error =
  let buffer = Bytes.create read_buffer_bytes in
  let rec loop () =
    match read_step t descriptor buffer with
    | Error error -> on_error error
    | Ok (Chunk outcome) ->
        on_outcome outcome;
        loop ()
    | Ok (Eof outcome) -> on_outcome outcome
  in
  loop ()
