type t = private int64
type error = [ `Negative of int64 | `Overflow ]

module E : Err.S with type error = error

val add : t -> t -> (t, error) Err.t
val compare : t -> t -> int
val equal : t -> t -> bool
val of_int64 : int64 -> (t, error) Err.t
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
val succ : t -> (t, error) Err.t
val to_int64 : t -> int64
