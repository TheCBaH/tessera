type t
type 'a field = Keep | Set of 'a
type delta

val set : 'a -> 'a field
val apply_delta : t -> delta -> t
val compose_delta : earlier:delta -> later:delta -> delta
val default : t
val empty_delta : delta
val pp : Format.formatter -> t -> unit
val pp_delta : Format.formatter -> delta -> unit
