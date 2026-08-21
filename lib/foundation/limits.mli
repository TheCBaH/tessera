type invalid_limit = { name : string; value : int }
type error = [ `Invalid_limit of invalid_limit ]
type t

module E : Err.S with type error = error

val make :
  max_columns:UInt.t ->
  max_control_bytes:UInt.t ->
  max_csi_params:UInt.t ->
  max_diagnostics:UInt.t ->
  max_rows:UInt.t ->
  max_slice_bytes:UInt.t ->
  max_snapshot_cells:UInt.t ->
  (t, error) Err.t

val max_columns : t -> UInt.t
val max_control_bytes : t -> UInt.t
val max_csi_params : t -> UInt.t
val max_diagnostics : t -> UInt.t
val max_rows : t -> UInt.t
val max_slice_bytes : t -> UInt.t
val max_snapshot_cells : t -> UInt.t
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
