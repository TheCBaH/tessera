type cursor_move =
  | Back of Tessera_foundation.UInt.t
  | Column of Tessera_foundation.Types.Column.t
  | Down of Tessera_foundation.UInt.t
  | Forward of Tessera_foundation.UInt.t
  | Position of Tessera_foundation.Types.coord
  | Row of Tessera_foundation.Types.Row.t
  | Up of Tessera_foundation.UInt.t

type erase =
  | Display of [ `Clear_above | `Clear_all | `Clear_below ]
  | Line of [ `Clear_left | `Clear_line | `Clear_right ]

type edit =
  | Delete_chars of Tessera_foundation.UInt.t
  | Delete_lines of Tessera_foundation.UInt.t
  | Erase_chars of Tessera_foundation.UInt.t
  | Insert_chars of Tessera_foundation.UInt.t
  | Insert_lines of Tessera_foundation.UInt.t

type margins = { bottom : Tessera_foundation.Types.Row.t; top : Tessera_foundation.Types.Row.t }

type t =
  | Backspace
  | Carriage_return
  | Edit of edit
  | Erase of erase
  | Horizontal_tab
  | Line_feed
  | Move_cursor of cursor_move
  | Print of Unicode.Grapheme_sequence.t
  | Reset
  | Resize of Tessera_foundation.Types.Size.t
  | Restore_cursor
  | Save_cursor
  | Scroll_down of Tessera_foundation.UInt.t
  | Scroll_up of Tessera_foundation.UInt.t
  | Set_margins of margins
  | Set_mode of Mode.delta
  | Set_style of Style.delta
  | Set_tab
  | Set_title of string
  | Switch_screen of Tessera_foundation.Types.screen

type operation = t

module Batch : sig
  type t

  val append : t -> t -> t
  val empty : t
  val fold_left : ('a -> operation -> 'a) -> 'a -> t -> 'a
  val normalize : t -> t
  val pp : Format.formatter -> t -> unit
  val singleton : operation -> t
end

val pp : Format.formatter -> t -> unit
