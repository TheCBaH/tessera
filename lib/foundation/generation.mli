type tag
type t = tag Id.t

val compare : t -> t -> int
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
val succ : t -> (t, UInt.error) Err.t
val zero : t
