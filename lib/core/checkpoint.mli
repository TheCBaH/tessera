(** A versioned, length-delimited, portable encoding of a completed [Session.t]: the canonical policy, the decoder
    continuation, and the renderer state, taken only after [Session.initial], a successful [Session.ingest], or a
    successful [Session.finish]. Restoring it performs no I/O and produces a runnable [Session.t] indistinguishable from
    the one that was captured. *)

type t

type error =
  [ `Decoder of Tessera_decoder.Decoder.checkpoint_error
  | `Duplicate_field of string
  | `Limits of Tessera_foundation.Limits.error
  | `Malformed of string
  | `Missing_field of string
  | `Renderer of Tessera_renderer.Renderer.checkpoint_error
  | `Unknown_version of int
  | `Wire of Tessera_foundation.Wire.error ]

module E : Err.S with type error = error

val current_version : int

val of_session : Session.t -> t
(** Capture a checkpoint. Never fails: every [Session.t] is already valid. *)

val to_session : t -> (Session.t, error) Err.t
(** Restore a session, rejecting an unknown version, a truncated or malformed length, a duplicate or missing field, or a
    bounded value that exceeds the restored policy's limits. *)

val of_bytes : bytes -> t
(** Wrap raw bytes for {!to_session} to validate; a host adapter owns actually persisting/loading them. *)

val to_bytes : t -> bytes
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
