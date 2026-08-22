type diagnostic =
  | Control_string_too_long of { kind : string; offset : Tessera_foundation.Byte_offset.t }
  | Invalid_utf8 of { offset : Tessera_foundation.Byte_offset.t }
  | Malformed_csi of { offset : Tessera_foundation.Byte_offset.t; reason : string }
  | Unsupported_sequence of { family : string; offset : Tessera_foundation.Byte_offset.t }

type observation = Diagnostic of diagnostic | Resize of Tessera_foundation.Types.Size.t
type item = Observation of observation | Update of Update.t

module Item_sequence : sig
  type t

  val append : t -> t -> t
  val empty : t
  val fold_left : ('a -> item -> 'a) -> 'a -> t -> 'a
  val pp : Format.formatter -> t -> unit
  val singleton : item -> t
end

module Observation_sequence : sig
  type t

  val append : t -> t -> t
  val empty : t
  val pp : Format.formatter -> t -> unit
  val singleton : observation -> t
end

val pp_diagnostic : Format.formatter -> diagnostic -> unit
val pp_item : Format.formatter -> item -> unit
val pp_observation : Format.formatter -> observation -> unit
