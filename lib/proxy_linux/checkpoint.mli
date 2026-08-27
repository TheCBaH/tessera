(** A proxy checkpoint: an outer versioned envelope around {!Tessera.Checkpoint} adding the two proxy-owned facts
    terminal-plan.md's "Terminfo, encoder, and checkpoints" section names -- the selected terminal description's
    identity and the observer sequence position -- both validated by the proxy when restoring. Deliberately excludes
    every host concern that same section names as out of scope: raw signals, descriptors, tasks/promises,
    process/lifecycle state, borrowed byte buffers, pixel geometry, or browser/CSS measurements. Restoring performs no
    I/O; the adapter (this package's composition root) re-opens the PTY/process/observer socket and re-selects its own
    terminal description separately before it resumes dequeuing ingress, exactly as terminal-plan.md specifies. *)

type t

type restored = {
  session : Tessera.session;
  description_identity : string option;
      (** {!Tessera_terminfo.Description.identity} of the description selected when this checkpoint was taken, or [None]
          if none was selected. The proxy adapter re-selects/validates its own description on resume; this is only a
          record of which one to prefer, not a serialized {!Tessera_terminfo.Description.t}. *)
  observer_position : Tessera_proxy_observer.Record.sequence;
      (** Feed to {!Tessera_proxy_observer.Ring.create}'s [~start_position] when constructing the resumed ring, so an
          already-holding observer client's cursor lines up exactly with the new ring's start -- it reads back "caught
          up", never a spurious gap -- instead of numbering restarting at zero underneath it. *)
}

type error =
  [ `Duplicate_field of string
  | `Inner of Tessera.Checkpoint.error
  | `Malformed of string
  | `Missing_field of string
  | `Unknown_version of int
  | `Wire of Tessera_foundation.Wire.error ]

module E : Err.S with type error = error

val current_version : int
val max_description_identity_bytes : int

val of_session :
  session:Tessera.session ->
  description_identity:string option ->
  observer_position:Tessera_proxy_observer.Record.sequence ->
  t
(** Capture a proxy checkpoint. Never fails: every input is already a valid, bounded domain value. *)

val to_restored : t -> (restored, error) Err.t
(** Restore, rejecting an unknown version, a truncated or malformed length, a duplicate or missing field, a description
    identity over {!max_description_identity_bytes}, or an inner {!Tessera.Checkpoint} that itself fails to restore
    (e.g. against its own policy's limits). *)

val of_bytes : bytes -> t
(** Wrap raw bytes for {!to_restored} to validate; a host adapter owns actually persisting/loading them. *)

val to_bytes : t -> bytes
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
