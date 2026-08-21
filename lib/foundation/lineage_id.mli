type tag
type t = tag Id.t

val compare : t -> t -> int
val equal : t -> t -> bool
val of_uint : UInt.t -> t
val pp : Format.formatter -> t -> unit
