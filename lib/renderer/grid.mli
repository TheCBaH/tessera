type t

val get : t -> Tessera_foundation.Types.coord -> Tessera_model.Cell.t
val iter : (Tessera_foundation.Types.coord -> Tessera_model.Cell.t -> unit) -> t -> unit
val resize : t -> Tessera_foundation.Types.Size.t -> t
val set : t -> Tessera_foundation.Types.coord -> Tessera_model.Cell.t -> t
val size : t -> Tessera_foundation.Types.Size.t
val stats : t -> int * int

val with_blank :
  size:Tessera_foundation.Types.Size.t -> line_id:Tessera_foundation.Line_id.t -> style:Tessera_model.Style.t -> t
