type error = [ `Generation_mismatch | `Lineage_mismatch ]
type t

module E : Err.S with type error = error

val after_generation : t -> Tessera_foundation.Generation.t
val before_generation : t -> Tessera_foundation.Generation.t
val compose : t -> t -> (t, error) Err.t
val empty : lineage_id:Tessera_foundation.Lineage_id.t -> generation:Tessera_foundation.Generation.t -> t
val lineage_id : t -> Tessera_foundation.Lineage_id.t
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
val successor : t -> Tessera_foundation.Generation.t -> t
