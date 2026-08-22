type error =
  [ `Generation_mismatch
  | `Incomplete_wide_pair
  | `Lineage_mismatch
  | `Unsupported_attachment
  | `Unsupported_observation
  | `Unsupported_presentation ]

type target

module E : Err.S with type error = error

val compile :
  Description.t ->
  Tessera_foundation.Policy.t ->
  target ->
  Tessera_renderer.Patch.t ->
  (target * Tessera_model.Update.Batch.t, error) Err.t

val active : target -> Tessera_foundation.Types.screen
val cells : target -> Tessera_model.Collection.Cell_blocks.t
val cursor : target -> Tessera_renderer.Patch.cursor
val cursor_visible : target -> bool
val generation : target -> Tessera_foundation.Generation.t
val modes : target -> Tessera_model.Mode.t

val initial :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  target

val pp_error : Format.formatter -> error -> unit
val pp_target : Format.formatter -> target -> unit
val size : target -> Tessera_foundation.Types.Size.t
val title : target -> string option
