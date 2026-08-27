type t

val get : t -> Tessera_foundation.Types.coord -> Tessera_model.Cell.t
val cells : t -> Tessera_model.Cell.t array
val fold_left : ('a -> Tessera_foundation.Types.coord -> Tessera_model.Cell.t -> 'a) -> 'a -> t -> 'a
val iter : (Tessera_foundation.Types.coord -> Tessera_model.Cell.t -> unit) -> t -> unit
val resize : t -> Tessera_foundation.Types.Size.t -> t
val set : t -> Tessera_foundation.Types.coord -> Tessera_model.Cell.t -> t
val size : t -> Tessera_foundation.Types.Size.t
val stats : t -> int * int

val with_blank :
  size:Tessera_foundation.Types.Size.t -> line_id:Tessera_foundation.Line_id.t -> style:Tessera_model.Style.t -> t

(** {2 Raw page access}

    A grid is physically stored in fixed [page_columns x page_rows] pages that persist beyond the current logical
    [size]: shrinking then re-growing [size] can resurface a page's earlier content, since [resize] only clips the
    logical view rather than erasing storage. A checkpoint must capture this raw page storage, not just the
    [size]-clipped [cells] view, or restoring then resizing larger could silently lose live off-view content. *)

val page_columns : int
val page_rows : int
val blank : t -> Tessera_model.Cell.t
val pages : t -> ((int * int) * Tessera_model.Cell.t array) list

val of_pages :
  blank:Tessera_model.Cell.t ->
  size:Tessera_foundation.Types.Size.t ->
  ((int * int) * Tessera_model.Cell.t array) list ->
  t option
(** [None] when any page's cell array is not exactly [page_columns * page_rows] long. *)
