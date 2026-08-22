type error = [ `Decode of Tessera_decoder.Decoder.error | `Render of Tessera_renderer.Renderer.error ]
type byte_input = Tessera_foundation.Types.slice
type out_of_band = Resize of Tessera_foundation.Types.Size.t
type input = Bytes of byte_input | Out_of_band of out_of_band
type outcome
type t

module E : Err.S with type error = error

val ingest : t -> input -> (outcome, error) Err.t
val finish : t -> (outcome, error) Err.t

val initial :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  t

val items : outcome -> Tessera_model.Effect.Item_sequence.t
val patch : outcome -> Tessera_renderer.Patch.t
val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
val pp_outcome : Format.formatter -> outcome -> unit
val snapshot : outcome -> Tessera_renderer.Renderer.snapshot
val successor : outcome -> t
