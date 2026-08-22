type error = [ `Compiled_format of string | `Description of Description.error | `Source_syntax of string ]
type resource = Compiled of bytes | Source of string

module E : Err.S with type error = error

val parse : Tessera_foundation.Policy.t -> resource -> (Description.t, error) Err.t
val pp_error : Format.formatter -> error -> unit
val pp_resource : Format.formatter -> resource -> unit
val resolve_use : Description.t -> lookup:(string -> Description.t option) -> (Description.t, error) Err.t
