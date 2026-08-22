type contents = Empty | Glyph of Unicode.grapheme | Wide_continuation
type t

val blank : line_id:Tessera_foundation.Line_id.t -> style:Style.t -> t
val contents : t -> contents
val equal : t -> t -> bool
val glyph : line_id:Tessera_foundation.Line_id.t -> style:Style.t -> Unicode.grapheme -> t
val line_id : t -> Tessera_foundation.Line_id.t
val pp : Format.formatter -> t -> unit
val pp_contents : Format.formatter -> contents -> unit
val style : t -> Style.t
val wide_continuation : line_id:Tessera_foundation.Line_id.t -> style:Style.t -> t
