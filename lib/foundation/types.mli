type error = [ `Invalid_rect | `Invalid_size | `Invalid_slice ]

module E : Err.S with type error = error

module Column : sig
  type t

  val compare : t -> t -> int
  val of_uint : UInt.t -> t
  val pp : Format.formatter -> t -> unit
  val to_uint : t -> UInt.t
end

module Row : sig
  type t

  val compare : t -> t -> int
  val of_uint : UInt.t -> t
  val pp : Format.formatter -> t -> unit
  val to_uint : t -> UInt.t
end

type coord = { column : Column.t; row : Row.t }
type rect
type screen = Alternate | Primary
type slice

module Size : sig
  type t

  val columns : t -> UInt.t
  val contains : t -> coord -> bool
  val make : columns:UInt.t -> rows:UInt.t -> (t, error) Err.t
  val pp : Format.formatter -> t -> unit
  val rows : t -> UInt.t
end

val coord : column:Column.t -> row:Row.t -> coord
val pp_coord : Format.formatter -> coord -> unit
val pp_error : Format.formatter -> error -> unit
val pp_rect : Format.formatter -> rect -> unit
val pp_screen : Format.formatter -> screen -> unit
val pp_slice : Format.formatter -> slice -> unit
val rect : bottom:Row.t -> left:Column.t -> right:Column.t -> top:Row.t -> (rect, error) Err.t
val slice : bytes -> len:UInt.t -> off:UInt.t -> (slice, error) Err.t
val slice_bytes : slice -> bytes
val slice_len : slice -> UInt.t
val slice_off : slice -> UInt.t
