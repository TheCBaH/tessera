type cursor_move =
  | Back of Tessera_foundation.UInt.t
  | Column of Tessera_foundation.Types.Column.t
  | Down of Tessera_foundation.UInt.t
  | Forward of Tessera_foundation.UInt.t
  | Next_line of Tessera_foundation.UInt.t
  | Position of Tessera_foundation.Types.coord
  | Previous_line of Tessera_foundation.UInt.t
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
  | Alternate_screen of [ `Enter_1049 | `Leave_1049 ]
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

let pp_uint = Tessera_foundation.UInt.pp
let pp_column = Tessera_foundation.Types.Column.pp
let pp_row = Tessera_foundation.Types.Row.pp

let pp_erase ppf = function
  | Display `Clear_above -> Format.pp_print_string ppf "display(clear-above)"
  | Display `Clear_all -> Format.pp_print_string ppf "display(clear-all)"
  | Display `Clear_below -> Format.pp_print_string ppf "display(clear-below)"
  | Line `Clear_left -> Format.pp_print_string ppf "line(clear-left)"
  | Line `Clear_line -> Format.pp_print_string ppf "line(clear-line)"
  | Line `Clear_right -> Format.pp_print_string ppf "line(clear-right)"

let pp_edit ppf = function
  | Delete_chars value -> Format.fprintf ppf "delete-chars(%a)" pp_uint value
  | Delete_lines value -> Format.fprintf ppf "delete-lines(%a)" pp_uint value
  | Erase_chars value -> Format.fprintf ppf "erase-chars(%a)" pp_uint value
  | Insert_chars value -> Format.fprintf ppf "insert-chars(%a)" pp_uint value
  | Insert_lines value -> Format.fprintf ppf "insert-lines(%a)" pp_uint value

let pp_margins ppf { bottom; top } = Format.fprintf ppf "{top=%a; bottom=%a}" pp_row top pp_row bottom

let pp_cursor_move ppf = function
  | Back value -> Format.fprintf ppf "back(%a)" pp_uint value
  | Column value -> Format.fprintf ppf "column(%a)" pp_column value
  | Down value -> Format.fprintf ppf "down(%a)" pp_uint value
  | Forward value -> Format.fprintf ppf "forward(%a)" pp_uint value
  | Next_line value -> Format.fprintf ppf "next-line(%a)" pp_uint value
  | Position value -> Format.fprintf ppf "position(%a)" Tessera_foundation.Types.pp_coord value
  | Previous_line value -> Format.fprintf ppf "previous-line(%a)" pp_uint value
  | Row value -> Format.fprintf ppf "row(%a)" pp_row value
  | Up value -> Format.fprintf ppf "up(%a)" pp_uint value

let pp ppf = function
  | Alternate_screen `Enter_1049 -> Format.pp_print_string ppf "alternate-screen(enter-1049)"
  | Alternate_screen `Leave_1049 -> Format.pp_print_string ppf "alternate-screen(leave-1049)"
  | Backspace -> Format.pp_print_string ppf "backspace"
  | Carriage_return -> Format.pp_print_string ppf "carriage-return"
  | Edit value -> Format.fprintf ppf "edit(%a)" pp_edit value
  | Erase value -> Format.fprintf ppf "erase(%a)" pp_erase value
  | Horizontal_tab -> Format.pp_print_string ppf "horizontal-tab"
  | Line_feed -> Format.pp_print_string ppf "line-feed"
  | Move_cursor value -> Format.fprintf ppf "move-cursor(%a)" pp_cursor_move value
  | Print value -> Format.fprintf ppf "print(%a)" Unicode.Grapheme_sequence.pp value
  | Reset -> Format.pp_print_string ppf "reset"
  | Resize value -> Format.fprintf ppf "resize(%a)" Tessera_foundation.Types.Size.pp value
  | Restore_cursor -> Format.pp_print_string ppf "restore-cursor"
  | Save_cursor -> Format.pp_print_string ppf "save-cursor"
  | Scroll_down value -> Format.fprintf ppf "scroll-down(%a)" pp_uint value
  | Scroll_up value -> Format.fprintf ppf "scroll-up(%a)" pp_uint value
  | Set_margins value -> Format.fprintf ppf "set-margins(%a)" pp_margins value
  | Set_mode value -> Format.fprintf ppf "set-mode(%a)" Mode.pp_delta value
  | Set_style value -> Format.fprintf ppf "set-style(%a)" Style.pp_delta value
  | Set_tab -> Format.pp_print_string ppf "set-tab"
  | Set_title value -> Format.fprintf ppf "set-title(%S)" value
  | Switch_screen value -> Format.fprintf ppf "switch-screen(%a)" Tessera_foundation.Types.pp_screen value

module Batch = struct
  type nonrec t = operation list

  let empty = []
  let singleton value = [ value ]
  let append = ( @ )
  let fold_left = List.fold_left

  let normalize value =
    let rec loop accumulator = function
      | Print left :: Print right :: rest ->
          loop accumulator (Print (Unicode.Grapheme_sequence.append left right) :: rest)
      | Set_style left :: Set_style right :: rest ->
          loop accumulator (Set_style (Style.compose_delta ~earlier:left ~later:right) :: rest)
      | Set_mode left :: Set_mode right :: rest ->
          loop accumulator (Set_mode (Mode.compose_delta ~earlier:left ~later:right) :: rest)
      | item :: rest -> loop (item :: accumulator) rest
      | [] -> List.rev accumulator
    in
    loop [] value

  let pp ppf value =
    Format.fprintf ppf "[%a]" (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp) value
end
