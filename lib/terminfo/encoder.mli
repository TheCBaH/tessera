type byte_chunks
type error = [ `Unexpressible_update of Tessera_model.Update.t ]

module E : Err.S with type error = error

val encode : Description.t -> Tessera_foundation.Policy.t -> Tessera_model.Update.Batch.t -> (byte_chunks, error) Err.t
val fold_chunks : ('a -> Tessera_foundation.Types.slice -> 'a) -> 'a -> byte_chunks -> 'a
val pp_byte_chunks : Format.formatter -> byte_chunks -> unit
val pp_error : Format.formatter -> error -> unit
