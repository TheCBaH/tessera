(** Async scheduler adapter: serialises {!Async.Reader.t} byte reads and validated resize requests through
    {!Tessera.Session.ingest}/{!Tessera.finish}, guaranteeing per-direction order (byte reads among themselves; resize
    requests among themselves) and that no two ingests race on the shared session. It has no PTY, signal, or ioctl
    dependency: a later platform layer turns host resize notifications into calls to {!resize}.

    This mirrors {!module:Tessera_unix.Unix_adapter}'s and {!module:Tessera_lwt.Lwt_adapter}'s design with Async's
    scheduler primitives: an {!Async.Throttle.Sequencer.t} (one job at a time) replaces {!Mutex.t}/{!Lwt_mutex.t}, held
    only around the brief session mutation, never around the pending {!Async.Reader.read} itself, so a concurrent
    {!resize} job is never stuck behind a read that has not resolved. The caller creates and owns the {!Async.Reader.t}
    (and the {!Async.Fd.t}/kind it wraps); this adapter only reads from it. *)

type t

type read_result =
  | Chunk of Tessera.outcome  (** One non-empty read was ingested. *)
  | Eof of Tessera.outcome  (** The reader reached end of file; {!Tessera.finish} was called. *)

type error =
  [ `Invalid_count of Tessera_foundation.UInt.error
  | `Invalid_value of Tessera_foundation.Types.error
  | `Read_failed of exn  (** An exception raised while reading, caught rather than sent to the ambient monitor. *)
  | `Session of Tessera.Session.error ]

module E : Err.S with type error = error

val create :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  t

val resize : t -> columns:int -> rows:int -> (Tessera.outcome, error) Err.t Async.Deferred.t
(** Safe to call concurrently with a {!run} loop reading the same [t]. This direction and the byte-read direction inside
    {!run} are each individually ordered, and never race on the shared session, but their relative interleaving is
    whatever order the two callers actually invoked them in (this adapter does not itself observe host resize signals).
*)

val read_step : t -> Async.Reader.t -> bytes -> (read_result, error) Err.t Async.Deferred.t
(** One {!Async.Reader.read} into [buffer], ingested through the session. [buffer] is owned and reused by the caller
    across calls; only the bytes actually read are drawn from it before the next call may overwrite it. *)

val run :
  t ->
  Async.Reader.t ->
  read_buffer_bytes:int ->
  on_outcome:(Tessera.outcome -> unit) ->
  on_error:(error Err.Error.t -> unit) ->
  unit Async.Deferred.t
(** Read loop: repeatedly calls {!read_step} until it reports {!Eof} (calling [on_outcome] for every ingested outcome
    along the way, including the final one) or reports an error (reported once via [on_error]; the loop then stops
    without calling [Session.finish]). The returned deferred becomes determined once the loop stops. *)

val pp_error : Format.formatter -> error -> unit
