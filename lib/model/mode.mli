type t
type 'a field = Keep | Set of 'a
type delta

val set : 'a -> 'a field
val apply_delta : t -> delta -> t
val ansi_mode_delta : enabled:bool -> int -> delta option
val compose_delta : earlier:delta -> later:delta -> delta
val auto_wrap : t -> bool
val cursor_visible : t -> bool
val default : t
val empty_delta : delta
val insert : t -> bool
val origin : t -> bool
val private_mode_delta : enabled:bool -> int -> delta option
val pp : Format.formatter -> t -> unit
val pp_delta : Format.formatter -> delta -> unit
