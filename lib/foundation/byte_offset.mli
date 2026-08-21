type t

val add : t -> UInt.t -> (t, UInt64.error) Err.t
val compare : t -> t -> int
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
val zero : t
