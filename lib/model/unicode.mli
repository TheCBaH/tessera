type decoder_continuation
type error = [ `Invalid_utf8 | `Unicode_limit_exceeded ]
type grapheme
type scalar = Uchar.t
type width = One | Two | Zero

module E : Err.S with type error = error

module Grapheme_sequence : sig
  type t

  val append : t -> t -> t
  val empty : t
  val fold_left : ('a -> grapheme -> 'a) -> 'a -> t -> 'a
  val singleton : grapheme -> t
  val utf8 : t -> string
  val pp : Format.formatter -> t -> unit
end

val feed :
  Tessera_foundation.Policy.t ->
  decoder_continuation ->
  scalar ->
  (decoder_continuation * Grapheme_sequence.t, error) Err.t

val finish : Tessera_foundation.Policy.t -> decoder_continuation -> (Grapheme_sequence.t, error) Err.t
val grapheme_of_scalar : scalar -> grapheme
val initial : decoder_continuation
val of_pending : scalar list -> decoder_continuation
val of_scalars : scalar list -> grapheme
val pending : decoder_continuation -> scalar list
val pp_decoder_continuation : Format.formatter -> decoder_continuation -> unit
val pp_error : Format.formatter -> error -> unit
val pp_grapheme : Format.formatter -> grapheme -> unit
val pp_scalar : Format.formatter -> scalar -> unit
val pp_width : Format.formatter -> width -> unit
val scalars : grapheme -> scalar list
val utf8 : grapheme -> string
val width : grapheme -> width
