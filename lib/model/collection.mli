module Cell_block : sig
  type t

  val pp : Format.formatter -> t -> unit
end

module Cell_blocks : sig
  type t

  val empty : t
  val fold_left : ('a -> Cell_block.t -> 'a) -> 'a -> t -> 'a
  val normalize : t -> t
  val pp : Format.formatter -> t -> unit
end

module Damage : sig
  type t

  val empty : t
  val singleton : Tessera_foundation.Types.rect -> t
  val union : t -> t -> t
  val pp : Format.formatter -> t -> unit
end

module Snapshot_cells : sig
  type t

  val get : t -> Tessera_foundation.Types.coord -> Cell.t
  val pp : Format.formatter -> t -> unit
  val size : t -> Tessera_foundation.Types.Size.t
end

module Tab_stops : sig
  type t

  val add : t -> Tessera_foundation.Types.Column.t -> t
  val empty : t
  val mem : t -> Tessera_foundation.Types.Column.t -> bool
  val pp : Format.formatter -> t -> unit
  val remove : t -> Tessera_foundation.Types.Column.t -> t
end
