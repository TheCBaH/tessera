type error = [ `Generation_mismatch | `Lineage_mismatch ]
type cursor = { pending_wrap : bool; position : Tessera_foundation.Types.coord; style : Tessera_model.Style.t }
type 'a change = Keep | Set of 'a

type presentation = {
  active : Tessera_foundation.Types.screen change;
  cursor : cursor change;
  cursor_visible : bool change;
  title : string option change;
}

type t

module E : Err.S with type error = error

val after_generation : t -> Tessera_foundation.Generation.t
val before_generation : t -> Tessera_foundation.Generation.t
val before_size : t -> Tessera_foundation.Types.Size.t
val cells : t -> Tessera_model.Collection.Cell_blocks.t
val compose : t -> t -> (t, error) Err.t
val damage : t -> Tessera_model.Collection.Damage.t

val empty :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  generation:Tessera_foundation.Generation.t ->
  size:Tessera_foundation.Types.Size.t ->
  t

val lineage_id : t -> Tessera_foundation.Lineage_id.t

val make :
  after_generation:Tessera_foundation.Generation.t ->
  before_generation:Tessera_foundation.Generation.t ->
  before_size:Tessera_foundation.Types.Size.t ->
  cells:Tessera_model.Collection.Cell_blocks.t ->
  damage:Tessera_model.Collection.Damage.t ->
  lineage_id:Tessera_foundation.Lineage_id.t ->
  presentation:presentation ->
  size:Tessera_foundation.Types.Size.t change ->
  t

val normalize : t -> t
val pp : Format.formatter -> t -> unit
val pp_cursor : Format.formatter -> cursor -> unit
val pp_error : Format.formatter -> error -> unit
val pp_presentation : Format.formatter -> presentation -> unit
val presentation : t -> presentation
val size : t -> Tessera_foundation.Types.Size.t change
val successor : t -> Tessera_foundation.Generation.t -> t
