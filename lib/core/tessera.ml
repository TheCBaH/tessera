module Foundation = struct
  module UInt = Tessera_foundation.UInt
  module UInt64 = Tessera_foundation.UInt64
  module Id = Tessera_foundation.Id
  module Byte_offset = Tessera_foundation.Byte_offset
  module Generation = Tessera_foundation.Generation
  module Line_id = Tessera_foundation.Line_id
  module Lineage_id = Tessera_foundation.Lineage_id
  module Types = Tessera_foundation.Types
  module Limits = Tessera_foundation.Limits
  module Policy = Tessera_foundation.Policy
end

module Model = struct
  module Style = Tessera_model.Style
  module Mode = Tessera_model.Mode
  module Unicode = Tessera_model.Unicode
  module Cell = Tessera_model.Cell
  module Collection = Tessera_model.Collection
  module Update = Tessera_model.Update
  module Effect = Tessera_model.Effect
end

module UInt = Foundation.UInt
module UInt64 = Foundation.UInt64
module Id = Foundation.Id
module Byte_offset = Foundation.Byte_offset
module Generation = Foundation.Generation
module Line_id = Foundation.Line_id
module Lineage_id = Foundation.Lineage_id
module Types = Foundation.Types
module Limits = Foundation.Limits
module Policy = Foundation.Policy
module Style = Model.Style
module Mode = Model.Mode
module Unicode = Model.Unicode
module Cell = Model.Cell
module Collection = Model.Collection
module Update = Model.Update
module Effect = Model.Effect
module Description = Tessera_terminfo.Description
module Terminfo = Tessera_terminfo.Terminfo
module Encoder = Tessera_terminfo.Encoder
module Repaint = Tessera_terminfo.Repaint
module Bundled = Tessera_terminfo.Bundled
module Patch = Tessera_renderer.Patch
module Renderer = Tessera_renderer.Renderer
module Decoder = Tessera_decoder.Decoder
module Session = Session
module Checkpoint = Checkpoint

type outcome = Session.outcome
type session = Session.t
type byte_input = Session.byte_input
type out_of_band = Session.out_of_band = Resize of Types.Size.t
type input = Session.input = Bytes of byte_input | Out_of_band of out_of_band

let ingest = Session.ingest
let finish = Session.finish
let initial = Session.initial
let outcome_items = Session.items
let outcome_patch = Session.patch
let outcome_snapshot = Session.snapshot
let pp_outcome = Session.pp_outcome
let pp_session = Session.pp
let session = Session.successor
