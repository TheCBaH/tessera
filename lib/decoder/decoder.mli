type continuation
type error = [ `Internal_invariant of string | `Invalid_slice | `Unicode of Tessera_model.Unicode.error ]
type decoded = { continuation : continuation; items : Tessera_model.Effect.Item_sequence.t }

module E : Err.S with type error = error

val feed : Tessera_foundation.Policy.t -> continuation -> Tessera_foundation.Types.slice -> (decoded, error) Err.t
val finish : Tessera_foundation.Policy.t -> continuation -> (decoded, error) Err.t
val initial : continuation
val pp : Format.formatter -> continuation -> unit
val pp_decoded : Format.formatter -> decoded -> unit
val pp_error : Format.formatter -> error -> unit
