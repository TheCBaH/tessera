type applied
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

val patch : applied -> Patch.t
val pp : Format.formatter -> state -> unit
val pp_applied : Format.formatter -> applied -> unit
val pp_error : Format.formatter -> error -> unit
val pp_snapshot : Format.formatter -> snapshot -> unit
val snapshot : applied -> snapshot
val state : applied -> state
