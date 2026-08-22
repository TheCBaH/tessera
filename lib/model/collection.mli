module Cell_block : sig
  type t

  val cell : t -> Cell.t
  val coord : t -> Tessera_foundation.Types.coord
  val fold_left : ('a -> Tessera_foundation.Types.coord -> Cell.t -> 'a) -> 'a -> t -> 'a
  val make : screen:Tessera_foundation.Types.screen -> coord:Tessera_foundation.Types.coord -> cell:Cell.t -> t
  val pp : Format.formatter -> t -> unit
  val rect : t -> Tessera_foundation.Types.rect
  val screen : t -> Tessera_foundation.Types.screen
end

module Cell_blocks : sig
  type t

  val append : t -> t -> t
  val empty : t
  val fold_left : ('a -> Cell_block.t -> 'a) -> 'a -> t -> 'a
  val of_list : Cell_block.t list -> t
  val normalize : t -> t
  val pp : Format.formatter -> t -> unit
end

module Damage : sig
  type t

  val empty : t
  val fold_left : ('a -> Tessera_foundation.Types.rect -> 'a) -> 'a -> t -> 'a
  val of_list : Tessera_foundation.Types.rect list -> t
  val normalize : t -> t
  val singleton : Tessera_foundation.Types.rect -> t
  val union : t -> t -> t
  val pp : Format.formatter -> t -> unit
end

module Snapshot_cells : sig
  type t

  val get : t -> Tessera_foundation.Types.coord -> Cell.t
  val of_row_major : size:Tessera_foundation.Types.Size.t -> Cell.t array -> t option
  val pp : Format.formatter -> t -> unit
  val size : t -> Tessera_foundation.Types.Size.t
end

module Tab_stops : sig
  type t

  val add : t -> Tessera_foundation.Types.Column.t -> t
  val empty : t
  val mem : t -> Tessera_foundation.Types.Column.t -> bool
  val next : t -> Tessera_foundation.Types.Column.t -> Tessera_foundation.Types.Column.t option
  val pp : Format.formatter -> t -> unit
  val remove : t -> Tessera_foundation.Types.Column.t -> t
end
