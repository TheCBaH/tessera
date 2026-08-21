type t = private int
type error = [ `Negative of int | `Overflow ]

module E : Err.S with type error = error

val add : t -> t -> (t, error) Err.t
val compare : t -> t -> int
val equal : t -> t -> bool
val max_value : t
val of_int : int -> (t, error) Err.t
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
val succ : t -> (t, error) Err.t
val to_int : t -> int
