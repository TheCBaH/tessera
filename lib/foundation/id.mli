type 'kind t = private UInt.t

val compare : 'kind t -> 'kind t -> int
val equal : 'kind t -> 'kind t -> bool
val of_uint : UInt.t -> 'kind t
val pp : Format.formatter -> 'kind t -> unit
val succ : 'kind t -> ('kind t, UInt.error) Err.t
