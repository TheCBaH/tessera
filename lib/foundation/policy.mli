type profile = Xterm_256color_core
type t

val limits : t -> Limits.t
val make : limits:Limits.t -> profile:profile -> t
val pp : Format.formatter -> t -> unit
val pp_profile : Format.formatter -> profile -> unit
val profile : t -> profile
