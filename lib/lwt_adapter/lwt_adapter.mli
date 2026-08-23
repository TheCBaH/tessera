(** Lwt scheduler adapter: serialises {!Lwt_unix.file_descr} byte reads and validated resize requests through
    {!Tessera.Session.ingest}/{!Tessera.finish}, guaranteeing per-direction order (byte reads among themselves; resize
    requests among themselves) and that no two ingests race on the shared session. It has no PTY, signal, or ioctl
    dependency: a later platform layer turns host resize notifications into calls to {!resize}.

    This mirrors {!module:Tessera_unix.Unix_adapter}'s design with Lwt's cooperative promises in place of OS threads and
    a mutex: {!Lwt_mutex.t} replaces {!Mutex.t}, and the blocking read is an {!Lwt_unix.read} promise that other Lwt
    tasks (including a concurrent {!resize}) run underneath while it is pending. *)

type t

type read_result =
  | Chunk of Tessera.outcome  (** One non-empty read was ingested. *)
  | Eof of Tessera.outcome  (** The descriptor reached end of file; {!Tessera.finish} was called. *)

type error =
  [ `Invalid_count of Tessera_foundation.UInt.error
  | `Invalid_value of Tessera_foundation.Types.error
  | `Read_failed of Unix.error * string * string
  | `Session of Tessera.Session.error ]

module E : Err.S with type error = error

val create :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  t

val resize : t -> columns:int -> rows:int -> (Tessera.outcome, error) Err.t Lwt.t
(** Safe to call concurrently with a {!run} loop reading the same [t] on the same Lwt event loop. This direction and the
    byte-read direction inside {!run} are each individually ordered, and never race on the shared session, but their
    relative interleaving is whatever order the two callers actually invoked them in (this adapter does not itself
    observe host resize signals). *)

val read_step : t -> Lwt_unix.file_descr -> bytes -> (read_result, error) Err.t Lwt.t
(** One {!Lwt_unix.read} on the descriptor into [buffer], ingested through the session. [buffer] is owned and reused by
    the caller across calls; only the bytes actually read are drawn from it before the next call may overwrite it. *)

val run :
  t ->
  Lwt_unix.file_descr ->
  read_buffer_bytes:int ->
  on_outcome:(Tessera.outcome -> unit) ->
  on_error:(error Err.Error.t -> unit) ->
  unit Lwt.t
(** Read loop: repeatedly calls {!read_step} until it reports {!Eof} (calling [on_outcome] for every ingested outcome
    along the way, including the final one) or reports an error (reported once via [on_error]; the loop then stops
    without calling [Session.finish]). The returned promise resolves once the loop stops. *)

val pp_error : Format.formatter -> error -> unit
