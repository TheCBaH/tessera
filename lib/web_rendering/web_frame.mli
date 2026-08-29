(** Pure OCaml projection of a renderer snapshot/patch into browser-target rows.

    A [t] carries no continuation instructions: a width-[Two] glyph is one instruction. Proving that a width-[Two]
    glyph's source cell actually had a matching [Wide_continuation] is {!of_outcome}'s job (it still has the source
    snapshot), not {!validate}'s (a frame alone cannot carry that evidence -- see {!rows_of_cells}). *)

type kind = Reset | Delta

type background_span = {
  start : Tessera_foundation.Types.Column.t;
  stop : Tessera_foundation.Types.Column.t;  (** Exclusive. *)
  style : Tessera_model.Style.t;
}

type glyph = {
  start : Tessera_foundation.Types.Column.t;
  width : Tessera_model.Unicode.width;
  text : string;  (** UTF-8. *)
  style : Tessera_model.Style.t;
}

type row = {
  index : Tessera_foundation.Types.Row.t;
  background : background_span list;  (** Increasing [start], partitioning the row. *)
  glyphs : glyph list;  (** Increasing [start], pairwise non-overlapping. *)
}

type presentation = {
  active : Tessera_foundation.Types.screen;
  cursor_position : Tessera_foundation.Types.coord;
  cursor_pending_wrap : bool;
  cursor_style : Tessera_model.Style.t;
  cursor_visible : bool;
  title : string option;
  size : Tessera_foundation.Types.Size.t;
  generation : Tessera_foundation.Generation.t;
  lineage_id : Tessera_foundation.Lineage_id.t;
}

type t = { kind : kind; rows : row list; presentation : presentation }

type error =
  [ `Background_gap of Tessera_foundation.Types.Row.t
  | `Background_overlap of Tessera_foundation.Types.Row.t
  | `Glyph_out_of_range of Tessera_foundation.Types.coord
  | `Glyph_overlap of Tessera_foundation.Types.coord
  | `Unpaired_wide_glyph of Tessera_foundation.Types.coord ]

module E : Err.S with type error = error

val rows_of_cells : Tessera_model.Collection.Snapshot_cells.t -> (row list, error) Err.t
(** Materialize every row of a snapshot's cells: coalesce adjacent same-style cells into background spans (a full
    partition of each row) and adjacent same-style glyph-bearing cells are each one glyph instruction (a width-[Two]
    glyph is a single instruction; its [Wide_continuation] cell is skipped, after checking it is actually
    [Wide_continuation] -- otherwise [`Unpaired_wide_glyph]). *)

val of_outcome :
  patch:Tessera_renderer.Patch.t option -> snapshot:Tessera_renderer.Renderer.snapshot -> (t, error) Err.t
(** [patch:None] always produces a [Reset] built from [snapshot] alone (first attach, lineage change, failed generation
    check -- the caller decides when, this only builds the frame). [patch:Some p] produces [Delta] with only [p]'s
    damaged rows, upgraded to [Reset] with every row when [p]'s size is [Set _] or its active screen changed.
    [presentation] is always taken from [snapshot]. *)

val validate : t -> (unit, error) Err.t
(** Frame-intrinsic only: every row's background spans partition the row's full column range with no gaps or overlaps;
    every row's glyphs are pairwise non-overlapping and lie within that same range. Ordinary glyph/background overlap is
    never flagged. Does not and cannot check wide-glyph source-continuation pairing (see {!rows_of_cells}). *)

val pp : Format.formatter -> t -> unit
val pp_background_span : Format.formatter -> background_span -> unit
val pp_error : Format.formatter -> error -> unit
val pp_glyph : Format.formatter -> glyph -> unit
val pp_kind : Format.formatter -> kind -> unit
val pp_presentation : Format.formatter -> presentation -> unit
val pp_row : Format.formatter -> row -> unit
