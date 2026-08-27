type applied
type cursor = { pending_wrap : bool; position : Tessera_foundation.Types.coord; style : Tessera_model.Style.t }
type damage
type error = [ `Identifier_exhausted | `Invalid_operation | `Snapshot_limit_exceeded ]
type snapshot
type state

type checkpoint_error =
  [ `Malformed of string  (** an unrecognised tag or an out-of-range value at the named field *)
  | `Policy_limit_exceeded of string  (** a well-formed value the restored policy's limits forbid *)
  | `Wire of Tessera_foundation.Wire.error ]
(** Errors specific to restoring a [state] from a checkpoint payload: distinct from [error], which only describes a
    failure of live [apply]. *)

module E : Err.S with type error = error
module CE : Err.S with type error = checkpoint_error

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
val pp_checkpoint_error : Format.formatter -> checkpoint_error -> unit
val pp_damage : Format.formatter -> damage -> unit
val pp_error : Format.formatter -> error -> unit
val pp_snapshot : Format.formatter -> snapshot -> unit
val snapshot : applied -> snapshot
val size : snapshot -> Tessera_foundation.Types.Size.t
val state : applied -> state
val title : snapshot -> string option
val make_state : generation:Tessera_foundation.Generation.t -> logical:State.t -> state
val state_generation : state -> Tessera_foundation.Generation.t
val state_logical : state -> State.t

val encode : Buffer.t -> state -> unit
(** Append a length-delimited encoding of [state], validated only insofar as the source value is already well formed. *)

val decode : Tessera_foundation.Wire.reader -> policy:Tessera_foundation.Policy.t -> (state, checkpoint_error) Err.t
(** Restore a [state] previously written by {!encode}, rejecting any bounded value that exceeds [policy]'s limits. *)
