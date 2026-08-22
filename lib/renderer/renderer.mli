type applied
type cursor = { pending_wrap : bool; position : Tessera_foundation.Types.coord; style : Tessera_model.Style.t }
type damage
type error = [ `Identifier_exhausted | `Invalid_operation | `Snapshot_limit_exceeded ]
type snapshot
type state

module E : Err.S with type error = error

val apply : Tessera_foundation.Policy.t -> state -> Tessera_model.Update.Batch.t -> (applied, error) Err.t

val initial :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  state

val damage : applied -> damage
val patch : applied -> Patch.t
val active : snapshot -> Tessera_foundation.Types.screen
val cells : snapshot -> Tessera_model.Collection.Snapshot_cells.t
val cursor : snapshot -> cursor
val cursor_visible : snapshot -> bool
val generation : snapshot -> Tessera_foundation.Generation.t
val lineage_id : snapshot -> Tessera_foundation.Lineage_id.t
val pp : Format.formatter -> state -> unit
val pp_applied : Format.formatter -> applied -> unit
val pp_damage : Format.formatter -> damage -> unit
val pp_error : Format.formatter -> error -> unit
val pp_snapshot : Format.formatter -> snapshot -> unit
val snapshot : applied -> snapshot
val size : snapshot -> Tessera_foundation.Types.Size.t
val state : applied -> state
val title : snapshot -> string option
