type cursor = { pending_wrap : bool; position : Tessera_foundation.Types.coord; style : Tessera_model.Style.t }
type saved_cursor = { origin : bool; position : Tessera_foundation.Types.coord; style : Tessera_model.Style.t }
type buffer
type t

val active : t -> Tessera_foundation.Types.screen
val active_buffer : t -> buffer
val alternate : t -> buffer
val cursor : buffer -> cursor
val grid : buffer -> Grid.t
val initial : lineage_id:Tessera_foundation.Lineage_id.t -> size:Tessera_foundation.Types.Size.t -> t
val lineage_id : t -> Tessera_foundation.Lineage_id.t
val modes : t -> Tessera_model.Mode.t
val margins : buffer -> Tessera_model.Update.margins
val map_buffers : t -> f:(buffer -> buffer) -> t
val primary : t -> buffer
val resize : t -> Tessera_foundation.Types.Size.t -> t
val saved : buffer -> saved_cursor option
val size : t -> Tessera_foundation.Types.Size.t
val switch_screen : t -> Tessera_foundation.Types.screen -> t
val tabs : buffer -> Tessera_model.Collection.Tab_stops.t
val title : t -> string option
val with_active_buffer : t -> buffer -> t
val with_cursor : buffer -> cursor -> buffer
val with_grid : buffer -> Grid.t -> buffer
val with_margins : buffer -> Tessera_model.Update.margins -> buffer
val with_modes : t -> Tessera_model.Mode.t -> t
val with_saved : buffer -> saved_cursor option -> buffer
val with_size : t -> Tessera_foundation.Types.Size.t -> t
val with_tabs : buffer -> Tessera_model.Collection.Tab_stops.t -> buffer
val with_title : t -> string option -> t
