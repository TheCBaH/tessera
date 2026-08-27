type continuation
type error = [ `Internal_invariant of string | `Invalid_slice | `Unicode of Tessera_model.Unicode.error ]
type decoded = { continuation : continuation; items : Tessera_model.Effect.Item_sequence.t }

type checkpoint_error =
  [ `Malformed of string  (** an unrecognised tag or an out-of-range value at the named field *)
  | `Policy_limit_exceeded of string  (** a well-formed value the restored policy's limits forbid *)
  | `Wire of Tessera_foundation.Wire.error ]
(** Errors specific to restoring a [continuation] from a checkpoint payload: distinct from [error], which only describes
    a failure of live [feed]/[finish] decoding. *)

module E : Err.S with type error = error
module CE : Err.S with type error = checkpoint_error

val feed : Tessera_foundation.Policy.t -> continuation -> Tessera_foundation.Types.slice -> (decoded, error) Err.t
val finish : Tessera_foundation.Policy.t -> continuation -> (decoded, error) Err.t
val initial : continuation
val pp : Format.formatter -> continuation -> unit
val pp_checkpoint_error : Format.formatter -> checkpoint_error -> unit
val pp_decoded : Format.formatter -> decoded -> unit
val pp_error : Format.formatter -> error -> unit

val encode_continuation : Buffer.t -> continuation -> unit
(** Append a length-delimited, policy-independent encoding of [continuation]. *)

val decode_continuation :
  Tessera_foundation.Wire.reader -> policy:Tessera_foundation.Policy.t -> (continuation, checkpoint_error) Err.t
(** Restore a [continuation] previously written by {!encode_continuation}, rejecting any bounded value that exceeds
    [policy]'s limits. *)
