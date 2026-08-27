type t

val add : t -> UInt.t -> (t, UInt64.error) Err.t
val compare : t -> t -> int
val equal : t -> t -> bool
val of_uint64 : UInt64.t -> t
val pp : Format.formatter -> t -> unit
val to_uint64 : t -> UInt64.t
val zero : t
