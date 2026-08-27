open Tessera_foundation
module Effect = Tessera_model.Effect
module Unicode = Tessera_model.Unicode
module Update = Tessera_model.Update

type control_string = Apc | Dcs | Pm | Sos

type parser =
  | Csi of string * Byte_offset.t
  | Csi_discard of Byte_offset.t
  | Discard_osc of Byte_offset.t
  | Discard_osc_escape of Byte_offset.t
  | Discard_string of control_string * Byte_offset.t
  | Discard_string_escape of control_string * Byte_offset.t
  | Escape of Byte_offset.t
  | Ground
  | Osc of string * Byte_offset.t
  | Osc_escape of string * Byte_offset.t

type utf8_bytes = { codepoint : int; minimum : int; offset : Byte_offset.t; remaining : int }

type continuation = {
  byte_offset : Byte_offset.t;
  diagnostics_left : UInt.t option;
  parser : parser;
  utf8 : Unicode.decoder_continuation;
  utf8_bytes : utf8_bytes option;
}

type error = [ `Internal_invariant of string | `Invalid_slice | `Unicode of Unicode.error ]
type decoded = { continuation : continuation; items : Effect.Item_sequence.t }

let pp_error ppf = function
  | `Internal_invariant message -> Format.fprintf ppf "internal invariant: %s" message
  | `Invalid_slice -> Format.pp_print_string ppf "invalid slice"
  | `Unicode error -> Unicode.pp_error ppf error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

type checkpoint_error = [ `Malformed of string | `Policy_limit_exceeded of string | `Wire of Wire.error ]

let pp_checkpoint_error ppf = function
  | `Malformed field -> Format.fprintf ppf "malformed %s" field
  | `Policy_limit_exceeded field -> Format.fprintf ppf "policy limit exceeded: %s" field
  | `Wire error -> Format.fprintf ppf "wire(%a)" Wire.pp_error error

module Checkpoint_error = struct
  type nonrec error = checkpoint_error

  let pp_error = pp_checkpoint_error
end

module CE = Err.Make (Checkpoint_error)

let initial =
  {
    byte_offset = Byte_offset.zero;
    diagnostics_left = None;
    parser = Ground;
    utf8 = Unicode.initial;
    utf8_bytes = None;
  }

let pp ppf (value : continuation) =
  let parser =
    match value.parser with
    | Csi _ | Csi_discard _ -> "csi"
    | Discard_osc _ | Discard_osc_escape _ | Discard_string _ | Discard_string_escape _ -> "discard-string"
    | Escape _ -> "escape"
    | Ground -> "ground"
    | Osc _ | Osc_escape _ -> "osc"
  in
  let bytes = match value.utf8_bytes with None -> "complete" | Some _ -> "partial" in
  let diagnostics =
    match value.diagnostics_left with None -> "uninitialised" | Some value -> string_of_int (UInt.to_int value)
  in
  Format.fprintf ppf "decoder-continuation(offset=%a; diagnostics=%s; %s; utf8=%a; bytes=%s)" Byte_offset.pp
    value.byte_offset diagnostics parser Unicode.pp_decoder_continuation value.utf8 bytes

let pp_decoded ppf (value : decoded) =
  Format.fprintf ppf "{continuation=%a; items=%a}" pp value.continuation Effect.Item_sequence.pp value.items

let uint value = match UInt.of_int value with Ok value -> value | Error _ -> assert false
let row value = Types.Row.of_uint (uint (max 0 value))
let column value = Types.Column.of_uint (uint (max 0 value))
let item update = Effect.Item_sequence.singleton (Effect.Update update)
let emit items update = Effect.Item_sequence.append items (item update)
let observation diagnostic = Effect.Item_sequence.singleton (Effect.Observation (Effect.Diagnostic diagnostic))

let diagnostic ~items ~diagnostics_left value =
  if UInt.equal diagnostics_left (uint 0) then (items, diagnostics_left)
  else (Effect.Item_sequence.append items (observation value), uint (UInt.to_int diagnostics_left - 1))

let string_kind = function Apc -> "APC" | Dcs -> "DCS" | Pm -> "PM" | Sos -> "SOS"

let discard_unsupported_string ~items ~diagnostics_left ~kind ~offset =
  let items, diagnostics_left =
    diagnostic ~items ~diagnostics_left (Effect.Unsupported_sequence { family = string_kind kind; offset })
  in
  (Discard_string (kind, offset), items, diagnostics_left)

let parameter values index default =
  match List.nth_opt values index with
  | None | Some "" -> default
  | Some value -> ( try int_of_string value with Failure _ -> default)

let csi_parameter_count params =
  let rec loop count index =
    if index = String.length params then count else loop (if params.[index] = ';' then count + 1 else count) (index + 1)
  in
  loop 1 0

let csi params final =
  let private_mode = String.length params > 0 && params.[0] = '?' in
  let params = if private_mode then String.sub params 1 (String.length params - 1) else params in
  let values = String.split_on_char ';' params in
  let valid =
    List.for_all
      (function
        | "" -> true
        | value -> (
            try
              ignore (int_of_string value);
              true
            with Failure _ -> false))
      values
  in
  if not valid then None
  else
    let count = uint (max 1 (parameter values 0 1)) in
    let position () =
      Update.Move_cursor
        (Update.Position (Types.coord ~column:(column (parameter values 1 1 - 1)) ~row:(row (parameter values 0 1 - 1))))
    in
    match final with
    | 'A' -> Some (Update.Move_cursor (Update.Up count))
    | 'B' -> Some (Update.Move_cursor (Update.Down count))
    | 'C' -> Some (Update.Move_cursor (Update.Forward count))
    | 'D' -> Some (Update.Move_cursor (Update.Back count))
    | 'E' -> Some (Update.Move_cursor (Update.Next_line count))
    | 'F' -> Some (Update.Move_cursor (Update.Previous_line count))
    | 'G' -> Some (Update.Move_cursor (Update.Column (column (parameter values 0 1 - 1))))
    | 'H' | 'f' -> Some (position ())
    | 'J' -> (
        match parameter values 0 0 with
        | 0 -> Some (Update.Erase (Update.Display `Clear_below))
        | 1 -> Some (Update.Erase (Update.Display `Clear_above))
        | 2 | 3 -> Some (Update.Erase (Update.Display `Clear_all))
        | _ -> None)
    | 'K' -> (
        match parameter values 0 0 with
        | 0 -> Some (Update.Erase (Update.Line `Clear_right))
        | 1 -> Some (Update.Erase (Update.Line `Clear_left))
        | 2 -> Some (Update.Erase (Update.Line `Clear_line))
        | _ -> None)
    | 'P' -> Some (Update.Edit (Update.Delete_chars count))
    | 'X' -> Some (Update.Edit (Update.Erase_chars count))
    | '@' -> Some (Update.Edit (Update.Insert_chars count))
    | 'L' -> Some (Update.Edit (Update.Insert_lines count))
    | 'M' -> Some (Update.Edit (Update.Delete_lines count))
    | 'S' -> Some (Update.Scroll_up count)
    | 'T' -> Some (Update.Scroll_down count)
    | 'd' -> Some (Update.Move_cursor (Update.Row (row (parameter values 0 1 - 1))))
    | 'r' when not private_mode ->
        let top = parameter values 0 1 - 1 and bottom = parameter values 1 1 - 1 in
        if top < bottom then Some (Update.Set_margins { top = row top; bottom = row bottom }) else None
    | 's' when not private_mode -> Some Update.Save_cursor
    | 'u' when not private_mode -> Some Update.Restore_cursor
    | 'm' ->
        let int value = if value = "" then 0 else try int_of_string value with Failure _ -> -1 in
        let rec sgr delta = function
          | [] -> Some delta
          | (("38" | "48") as channel) :: "5" :: index :: rest -> (
              match Tessera_model.Style.indexed_color_delta ~foreground:(channel = "38") (int index) with
              | None -> None
              | Some update -> sgr (Tessera_model.Style.compose_delta ~earlier:delta ~later:update) rest)
          | (("38" | "48") as channel) :: "2" :: red :: green :: blue :: rest -> (
              match
                Tessera_model.Style.rgb_color_delta ~foreground:(channel = "38") ~red:(int red) ~green:(int green)
                  ~blue:(int blue)
              with
              | None -> None
              | Some update -> sgr (Tessera_model.Style.compose_delta ~earlier:delta ~later:update) rest)
          | value :: rest -> (
              match Tessera_model.Style.sgr_delta (int value) with
              | None -> None
              | Some update -> sgr (Tessera_model.Style.compose_delta ~earlier:delta ~later:update) rest)
        in
        Option.map (fun delta -> Update.Set_style delta) (sgr Tessera_model.Style.empty_delta values)
    | ('h' | 'l') when private_mode -> (
        let enabled = final = 'h' in
        match values with
        | [ "47" ] | [ "1047" ] -> Some (Update.Switch_screen (if enabled then Types.Alternate else Types.Primary))
        | [ "1049" ] -> Some (Update.Alternate_screen (if enabled then `Enter_1049 else `Leave_1049))
        | _ ->
            let rec modes delta = function
              | [] -> Some delta
              | value :: rest -> (
                  let value = if value = "" then -1 else try int_of_string value with Failure _ -> -1 in
                  match Tessera_model.Mode.private_mode_delta ~enabled value with
                  | None -> None
                  | Some update -> modes (Tessera_model.Mode.compose_delta ~earlier:delta ~later:update) rest)
            in
            Option.map (fun delta -> Update.Set_mode delta) (modes Tessera_model.Mode.empty_delta values))
    | 'h' | 'l' -> (
        let enabled = final = 'h' in
        match values with
        | [ value ] ->
            let value = if value = "" then -1 else try int_of_string value with Failure _ -> -1 in
            Option.map (fun delta -> Update.Set_mode delta) (Tessera_model.Mode.ansi_mode_delta ~enabled value)
        | _ -> None)
    | _ -> None

let osc payload =
  match String.split_on_char ';' payload with
  | ("0" | "2") :: title -> Some (Update.Set_title (String.concat ";" title))
  | _ -> None

let feed policy (continuation : continuation) slice =
  if UInt.compare (Types.slice_len slice) (Limits.max_slice_bytes (Policy.limits policy)) > 0 then E.fail `Invalid_slice
  else
    let bytes = Types.slice_bytes slice in
    let start = UInt.to_int (Types.slice_off slice) and length = UInt.to_int (Types.slice_len slice) in
    let diagnostics_left =
      match continuation.diagnostics_left with
      | None -> Limits.max_diagnostics (Policy.limits policy)
      | Some value ->
          if UInt.compare value (Limits.max_diagnostics (Policy.limits policy)) > 0 then
            Limits.max_diagnostics (Policy.limits policy)
          else value
    in
    let flush ~items ~utf8 =
      match Unicode.finish policy utf8 with
      | Error error -> Error (`Unicode (Err.Error.kind error))
      | Ok graphemes ->
          Ok
            ( Unicode.initial,
              if graphemes = Unicode.Grapheme_sequence.empty then items else emit items (Update.Print graphemes) )
    in
    let scalar ~items ~utf8 value =
      match Unicode.feed policy utf8 (Uchar.of_int value) with
      | Error error -> Error (`Unicode (Err.Error.kind error))
      | Ok (next, graphemes) ->
          Ok (next, if graphemes = Unicode.Grapheme_sequence.empty then items else emit items (Update.Print graphemes))
    in
    let complete_osc ~items ~diagnostics_left ~offset payload =
      match osc payload with
      | Some update -> (emit items update, diagnostics_left)
      | None -> diagnostic ~items ~diagnostics_left (Effect.Unsupported_sequence { family = "OSC"; offset })
    in
    let rec byte ~byte_offset ~diagnostics_left ~items ~parser ~utf8 ~utf8_bytes value =
      match utf8_bytes with
      | Some pending when value >= 0x80 && value <= 0xbf ->
          let codepoint = (pending.codepoint lsl 6) lor (value land 0x3f) in
          if pending.remaining = 1 then
            if codepoint < pending.minimum || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff) then
              let items, diagnostics_left =
                diagnostic ~items ~diagnostics_left (Effect.Invalid_utf8 { offset = pending.offset })
              in
              match scalar ~items ~utf8 0xfffd with
              | Ok (utf8, items) -> Ok (parser, utf8, None, diagnostics_left, items)
              | Error _ as error -> error
            else
              match scalar ~items ~utf8 codepoint with
              | Ok (utf8, items) -> Ok (parser, utf8, None, diagnostics_left, items)
              | Error _ as error -> error
          else
            Ok
              (parser, utf8, Some { pending with codepoint; remaining = pending.remaining - 1 }, diagnostics_left, items)
      | Some pending -> (
          let items, diagnostics_left =
            diagnostic ~items ~diagnostics_left (Effect.Invalid_utf8 { offset = pending.offset })
          in
          match scalar ~items ~utf8 0xfffd with
          | Error _ as error -> error
          | Ok (utf8, items) -> byte ~byte_offset ~diagnostics_left ~items ~parser ~utf8 ~utf8_bytes:None value)
      | None -> (
          match parser with
          | Csi _ | Csi_discard _ | Discard_osc _ | Discard_osc_escape _ | Discard_string _ | Discard_string_escape _
          | Escape _ | Osc _ | Osc_escape _
            when value = 0x18 || value = 0x1a ->
              Ok (Ground, utf8, None, diagnostics_left, items)
          | parser -> (
              match parser with
              | Ground -> (
                  match value with
                  | 0x1b -> (
                      match flush ~items ~utf8 with
                      | Ok (utf8, items) -> Ok (Escape byte_offset, utf8, None, diagnostics_left, items)
                      | Error _ as error -> error)
                  | 0x18 | 0x1a -> Ok (Ground, utf8, None, diagnostics_left, items)
                  | 0x84 -> Ok (Ground, utf8, None, diagnostics_left, emit items (Update.Scroll_up (uint 1)))
                  | 0x85 ->
                      Ok
                        (Ground, utf8, None, diagnostics_left, emit (emit items Update.Carriage_return) Update.Line_feed)
                  | 0x88 -> Ok (Ground, utf8, None, diagnostics_left, emit items Update.Set_tab)
                  | 0x8d -> Ok (Ground, utf8, None, diagnostics_left, emit items (Update.Scroll_down (uint 1)))
                  | 0x90 | 0x98 | 0x9b | 0x9c | 0x9d | 0x9e | 0x9f -> (
                      match flush ~items ~utf8 with
                      | Error _ as error -> error
                      | Ok (utf8, items) ->
                          let parser, items, diagnostics_left =
                            match value with
                            | 0x90 -> discard_unsupported_string ~items ~diagnostics_left ~kind:Dcs ~offset:byte_offset
                            | 0x98 -> discard_unsupported_string ~items ~diagnostics_left ~kind:Sos ~offset:byte_offset
                            | 0x9b -> (Csi ("", byte_offset), items, diagnostics_left)
                            | 0x9c -> (Ground, items, diagnostics_left)
                            | 0x9d -> (Osc ("", byte_offset), items, diagnostics_left)
                            | 0x9e -> discard_unsupported_string ~items ~diagnostics_left ~kind:Pm ~offset:byte_offset
                            | _ -> discard_unsupported_string ~items ~diagnostics_left ~kind:Apc ~offset:byte_offset
                          in
                          Ok (parser, utf8, None, diagnostics_left, items))
                  | 7 ->
                      let items, diagnostics_left =
                        diagnostic ~items ~diagnostics_left
                          (Effect.Unsupported_sequence { family = "BEL"; offset = byte_offset })
                      in
                      Ok (Ground, utf8, None, diagnostics_left, items)
                  | 8 | 9 | 10 | 11 | 12 | 13 -> (
                      match flush ~items ~utf8 with
                      | Error _ as error -> error
                      | Ok (utf8, items) ->
                          let update =
                            match value with
                            | 8 -> Update.Backspace
                            | 9 -> Update.Horizontal_tab
                            | 13 -> Update.Carriage_return
                            | _ -> Update.Line_feed
                          in
                          Ok (Ground, utf8, None, diagnostics_left, emit items update))
                  | value when value >= 32 && value < 127 -> (
                      match scalar ~items ~utf8 value with
                      | Ok (utf8, items) -> Ok (Ground, utf8, None, diagnostics_left, items)
                      | Error _ as error -> error)
                  | value when value >= 0xc2 && value <= 0xdf ->
                      Ok
                        ( Ground,
                          utf8,
                          Some { codepoint = value land 0x1f; minimum = 0x80; offset = byte_offset; remaining = 1 },
                          diagnostics_left,
                          items )
                  | value when value >= 0xe0 && value <= 0xef ->
                      Ok
                        ( Ground,
                          utf8,
                          Some { codepoint = value land 0x0f; minimum = 0x800; offset = byte_offset; remaining = 2 },
                          diagnostics_left,
                          items )
                  | value when value >= 0xf0 && value <= 0xf4 ->
                      Ok
                        ( Ground,
                          utf8,
                          Some { codepoint = value land 0x07; minimum = 0x10000; offset = byte_offset; remaining = 3 },
                          diagnostics_left,
                          items )
                  | _ -> (
                      let items, diagnostics_left =
                        diagnostic ~items ~diagnostics_left (Effect.Invalid_utf8 { offset = byte_offset })
                      in
                      match scalar ~items ~utf8 0xfffd with
                      | Ok (utf8, items) -> Ok (Ground, utf8, None, diagnostics_left, items)
                      | Error _ as error -> error))
              | Escape offset -> (
                  match Char.chr value with
                  | '[' -> Ok (Csi ("", offset), utf8, None, diagnostics_left, items)
                  | ']' -> Ok (Osc ("", offset), utf8, None, diagnostics_left, items)
                  | 'P' ->
                      let parser, items, diagnostics_left =
                        discard_unsupported_string ~items ~diagnostics_left ~kind:Dcs ~offset
                      in
                      Ok (parser, utf8, None, diagnostics_left, items)
                  | 'X' ->
                      let parser, items, diagnostics_left =
                        discard_unsupported_string ~items ~diagnostics_left ~kind:Sos ~offset
                      in
                      Ok (parser, utf8, None, diagnostics_left, items)
                  | '7' -> Ok (Ground, utf8, None, diagnostics_left, emit items Update.Save_cursor)
                  | '8' -> Ok (Ground, utf8, None, diagnostics_left, emit items Update.Restore_cursor)
                  | 'D' -> Ok (Ground, utf8, None, diagnostics_left, emit items (Update.Scroll_up (uint 1)))
                  | 'E' ->
                      Ok
                        (Ground, utf8, None, diagnostics_left, emit (emit items Update.Carriage_return) Update.Line_feed)
                  | 'H' -> Ok (Ground, utf8, None, diagnostics_left, emit items Update.Set_tab)
                  | 'M' -> Ok (Ground, utf8, None, diagnostics_left, emit items (Update.Scroll_down (uint 1)))
                  | '^' ->
                      let parser, items, diagnostics_left =
                        discard_unsupported_string ~items ~diagnostics_left ~kind:Pm ~offset
                      in
                      Ok (parser, utf8, None, diagnostics_left, items)
                  | '_' ->
                      let parser, items, diagnostics_left =
                        discard_unsupported_string ~items ~diagnostics_left ~kind:Apc ~offset
                      in
                      Ok (parser, utf8, None, diagnostics_left, items)
                  | 'c' -> Ok (Ground, utf8, None, diagnostics_left, emit items Update.Reset)
                  | _ ->
                      let items, diagnostics_left =
                        diagnostic ~items ~diagnostics_left (Effect.Unsupported_sequence { family = "ESC"; offset })
                      in
                      Ok (Ground, utf8, None, diagnostics_left, items))
              | Csi (params, offset) ->
                  if value >= 0x40 && value <= 0x7e then
                    let items, diagnostics_left =
                      match csi params (Char.chr value) with
                      | Some update -> (emit items update, diagnostics_left)
                      | None ->
                          diagnostic ~items ~diagnostics_left (Effect.Unsupported_sequence { family = "CSI"; offset })
                    in
                    Ok (Ground, utf8, None, diagnostics_left, items)
                  else if value >= 0x20 && value <= 0x3f then
                    let params = params ^ String.make 1 (Char.chr value) in
                    if csi_parameter_count params > UInt.to_int (Limits.max_csi_params (Policy.limits policy)) then
                      let items, diagnostics_left =
                        diagnostic ~items ~diagnostics_left
                          (Effect.Malformed_csi { offset; reason = "parameter count exceeds policy" })
                      in
                      Ok (Csi_discard offset, utf8, None, diagnostics_left, items)
                    else if String.length params > UInt.to_int (Limits.max_control_bytes (Policy.limits policy)) then
                      let items, diagnostics_left =
                        diagnostic ~items ~diagnostics_left
                          (Effect.Malformed_csi { offset; reason = "byte budget exceeds policy" })
                      in
                      Ok (Csi_discard offset, utf8, None, diagnostics_left, items)
                    else Ok (Csi (params, offset), utf8, None, diagnostics_left, items)
                  else
                    let items, diagnostics_left =
                      diagnostic ~items ~diagnostics_left (Effect.Malformed_csi { offset; reason = "invalid byte" })
                    in
                    Ok (Ground, utf8, None, diagnostics_left, items)
              | Csi_discard _ as parser ->
                  if value >= 0x40 && value <= 0x7e then Ok (Ground, utf8, None, diagnostics_left, items)
                  else Ok (parser, utf8, None, diagnostics_left, items)
              | Osc (payload, offset) ->
                  if value = 7 || value = 0x9c then
                    let items, diagnostics_left = complete_osc ~items ~diagnostics_left ~offset payload in
                    Ok (Ground, utf8, None, diagnostics_left, items)
                  else if value = 0x1b then Ok (Osc_escape (payload, offset), utf8, None, diagnostics_left, items)
                  else if String.length payload >= UInt.to_int (Limits.max_control_bytes (Policy.limits policy)) then
                    let items, diagnostics_left =
                      diagnostic ~items ~diagnostics_left (Effect.Control_string_too_long { kind = "OSC"; offset })
                    in
                    Ok (Discard_osc offset, utf8, None, diagnostics_left, items)
                  else Ok (Osc (payload ^ String.make 1 (Char.chr value), offset), utf8, None, diagnostics_left, items)
              | Osc_escape (payload, offset) ->
                  if value = Char.code '\\' then
                    let items, diagnostics_left = complete_osc ~items ~diagnostics_left ~offset payload in
                    Ok (Ground, utf8, None, diagnostics_left, items)
                  else if String.length payload + 2 > UInt.to_int (Limits.max_control_bytes (Policy.limits policy)) then
                    let items, diagnostics_left =
                      diagnostic ~items ~diagnostics_left (Effect.Control_string_too_long { kind = "OSC"; offset })
                    in
                    Ok (Discard_osc offset, utf8, None, diagnostics_left, items)
                  else
                    Ok
                      ( Osc (payload ^ "\027" ^ String.make 1 (Char.chr value), offset),
                        utf8,
                        None,
                        diagnostics_left,
                        items )
              | Discard_osc offset ->
                  if value = 0x9c || value = 7 then Ok (Ground, utf8, None, diagnostics_left, items)
                  else if value = 0x1b then Ok (Discard_osc_escape offset, utf8, None, diagnostics_left, items)
                  else Ok (Discard_osc offset, utf8, None, diagnostics_left, items)
              | Discard_osc_escape offset ->
                  if value = Char.code '\\' then Ok (Ground, utf8, None, diagnostics_left, items)
                  else Ok (Discard_osc offset, utf8, None, diagnostics_left, items)
              | Discard_string (kind, offset) ->
                  if value = 0x9c then Ok (Ground, utf8, None, diagnostics_left, items)
                  else if value = 0x1b then
                    Ok (Discard_string_escape (kind, offset), utf8, None, diagnostics_left, items)
                  else Ok (Discard_string (kind, offset), utf8, None, diagnostics_left, items)
              | Discard_string_escape (kind, offset) ->
                  if value = Char.code '\\' then Ok (Ground, utf8, None, diagnostics_left, items)
                  else Ok (Discard_string (kind, offset), utf8, None, diagnostics_left, items)))
    in
    let rec loop ~byte_offset ~diagnostics_left ~items ~parser ~utf8 ~utf8_bytes index =
      if index = start + length then
        Ok { continuation = { byte_offset; diagnostics_left = Some diagnostics_left; parser; utf8; utf8_bytes }; items }
      else
        match
          byte ~byte_offset ~diagnostics_left ~items ~parser ~utf8 ~utf8_bytes (Char.code (Bytes.get bytes index))
        with
        | Error error -> E.fail error
        | Ok (parser, utf8, utf8_bytes, diagnostics_left, items) -> (
            match Byte_offset.add byte_offset (uint 1) with
            | Error _ -> E.fail (`Internal_invariant "byte offset overflow")
            | Ok byte_offset -> loop ~byte_offset ~diagnostics_left ~items ~parser ~utf8 ~utf8_bytes (index + 1))
    in
    loop ~byte_offset:continuation.byte_offset ~diagnostics_left ~items:Effect.Item_sequence.empty
      ~parser:continuation.parser ~utf8:continuation.utf8 ~utf8_bytes:continuation.utf8_bytes start

let finish policy (continuation : continuation) =
  let diagnostics_left =
    match continuation.diagnostics_left with
    | None -> Limits.max_diagnostics (Policy.limits policy)
    | Some value -> value
  in
  let items, diagnostics_left, utf8 =
    match continuation.utf8_bytes with
    | None -> (Effect.Item_sequence.empty, diagnostics_left, Ok continuation.utf8)
    | Some pending ->
        let items, diagnostics_left =
          diagnostic ~items:Effect.Item_sequence.empty ~diagnostics_left
            (Effect.Invalid_utf8 { offset = pending.offset })
        in
        (items, diagnostics_left, Unicode.feed policy continuation.utf8 (Uchar.of_int 0xfffd) |> Result.map fst)
  in
  match utf8 with
  | Error error -> E.fail (`Unicode (Err.Error.kind error))
  | Ok utf8 -> (
      match Unicode.finish policy utf8 with
      | Error error -> E.fail (`Unicode (Err.Error.kind error))
      | Ok graphemes ->
          let items =
            if graphemes = Unicode.Grapheme_sequence.empty then items else emit items (Update.Print graphemes)
          in
          let items, diagnostics_left =
            match continuation.parser with
            | Csi (_, offset) | Csi_discard offset ->
                diagnostic ~items ~diagnostics_left (Effect.Malformed_csi { offset; reason = "unterminated sequence" })
            | Escape offset ->
                diagnostic ~items ~diagnostics_left (Effect.Unsupported_sequence { family = "ESC"; offset })
            | Osc (_, offset) | Osc_escape (_, offset) ->
                diagnostic ~items ~diagnostics_left (Effect.Unsupported_sequence { family = "OSC"; offset })
            | Discard_osc _ | Discard_osc_escape _ | Discard_string _ | Discard_string_escape _ | Ground ->
                (items, diagnostics_left)
          in
          Ok
            {
              continuation =
                {
                  byte_offset = continuation.byte_offset;
                  diagnostics_left = Some diagnostics_left;
                  parser = Ground;
                  utf8 = Unicode.initial;
                  utf8_bytes = None;
                };
              items;
            })

(* Checkpoint codec: a fixed-order, length-delimited encoding of [continuation]. Field order is part of this
   version's wire contract; a future incompatible layout must be a new [Tessera.Checkpoint] version rather than a
   silent reorder. *)

let ( let* ) = Result.bind

let wire_read read reader =
  match read reader with Error error -> CE.fail (`Wire (Err.Error.kind error)) | Ok value -> Ok value

let encode_byte_offset buffer offset = Wire.write_varint64 buffer (UInt64.to_int64 (Byte_offset.to_uint64 offset))

let decode_byte_offset reader =
  let* raw = wire_read Wire.read_varint64 reader in
  match UInt64.of_int64 raw with
  | Error _ -> CE.fail (`Malformed "byte offset")
  | Ok value -> Ok (Byte_offset.of_uint64 value)

let encode_control_string buffer = function
  | Apc -> Wire.write_u8 buffer 0
  | Dcs -> Wire.write_u8 buffer 1
  | Pm -> Wire.write_u8 buffer 2
  | Sos -> Wire.write_u8 buffer 3

let decode_control_string reader =
  let* tag = wire_read Wire.read_u8 reader in
  match tag with
  | 0 -> Ok Apc
  | 1 -> Ok Dcs
  | 2 -> Ok Pm
  | 3 -> Ok Sos
  | _ -> CE.fail (`Malformed "control string kind")

let encode_diagnostics_left buffer = function
  | None -> Wire.write_bool buffer false
  | Some value ->
      Wire.write_bool buffer true;
      Wire.write_varint buffer (UInt.to_int value)

let decode_diagnostics_left reader ~policy =
  let* present = wire_read Wire.read_bool reader in
  if not present then Ok None
  else
    let* raw = wire_read Wire.read_varint reader in
    match UInt.of_int raw with
    | Error _ -> CE.fail (`Malformed "diagnostics left")
    | Ok value ->
        if UInt.compare value (Limits.max_diagnostics (Policy.limits policy)) > 0 then
          CE.fail (`Policy_limit_exceeded "diagnostics left")
        else Ok (Some value)

let control_bytes_limit policy = UInt.to_int (Limits.max_control_bytes (Policy.limits policy))

let validate_control_bytes ~policy ~field length =
  if length > control_bytes_limit policy then CE.fail (`Policy_limit_exceeded field) else Ok ()

let encode_utf8 buffer utf8 =
  let scalars = Unicode.pending utf8 in
  Wire.write_varint buffer (List.length scalars);
  List.iter (fun scalar -> Wire.write_varint buffer (Uchar.to_int scalar)) scalars

let decode_utf8 reader ~policy =
  let* count = wire_read Wire.read_varint reader in
  if count < 0 then CE.fail (`Malformed "utf8 pending length")
  else if count > control_bytes_limit policy then CE.fail (`Policy_limit_exceeded "utf8 pending length")
  else
    let rec loop remaining acc =
      if remaining = 0 then Ok (List.rev acc)
      else
        let* raw = wire_read Wire.read_varint reader in
        if raw < 0 || not (Uchar.is_valid raw) then CE.fail (`Malformed "utf8 pending scalar")
        else loop (remaining - 1) (Uchar.of_int raw :: acc)
    in
    let* scalars = loop count [] in
    Ok (Unicode.of_pending scalars)

let encode_utf8_bytes buffer = function
  | None -> Wire.write_bool buffer false
  | Some { codepoint; minimum; offset; remaining } ->
      Wire.write_bool buffer true;
      Wire.write_varint buffer codepoint;
      Wire.write_varint buffer minimum;
      encode_byte_offset buffer offset;
      Wire.write_varint buffer remaining

let decode_utf8_bytes reader =
  let* present = wire_read Wire.read_bool reader in
  if not present then Ok None
  else
    let* codepoint = wire_read Wire.read_varint reader in
    let* minimum = wire_read Wire.read_varint reader in
    let* offset = decode_byte_offset reader in
    let* remaining = wire_read Wire.read_varint reader in
    Ok (Some { codepoint; minimum; offset; remaining })

let encode_parser buffer = function
  | Ground -> Wire.write_u8 buffer 0
  | Escape offset ->
      Wire.write_u8 buffer 1;
      encode_byte_offset buffer offset
  | Csi (params, offset) ->
      Wire.write_u8 buffer 2;
      Wire.write_string buffer params;
      encode_byte_offset buffer offset
  | Csi_discard offset ->
      Wire.write_u8 buffer 3;
      encode_byte_offset buffer offset
  | Osc (payload, offset) ->
      Wire.write_u8 buffer 4;
      Wire.write_string buffer payload;
      encode_byte_offset buffer offset
  | Osc_escape (payload, offset) ->
      Wire.write_u8 buffer 5;
      Wire.write_string buffer payload;
      encode_byte_offset buffer offset
  | Discard_osc offset ->
      Wire.write_u8 buffer 6;
      encode_byte_offset buffer offset
  | Discard_osc_escape offset ->
      Wire.write_u8 buffer 7;
      encode_byte_offset buffer offset
  | Discard_string (kind, offset) ->
      Wire.write_u8 buffer 8;
      encode_control_string buffer kind;
      encode_byte_offset buffer offset
  | Discard_string_escape (kind, offset) ->
      Wire.write_u8 buffer 9;
      encode_control_string buffer kind;
      encode_byte_offset buffer offset

let decode_parser reader ~policy =
  let* tag = wire_read Wire.read_u8 reader in
  match tag with
  | 0 -> Ok Ground
  | 1 ->
      let* offset = decode_byte_offset reader in
      Ok (Escape offset)
  | 2 ->
      let* params = wire_read Wire.read_string reader in
      let* () = validate_control_bytes ~policy ~field:"csi params" (String.length params) in
      let* () =
        if csi_parameter_count params > UInt.to_int (Limits.max_csi_params (Policy.limits policy)) then
          CE.fail (`Policy_limit_exceeded "csi params count")
        else Ok ()
      in
      let* offset = decode_byte_offset reader in
      Ok (Csi (params, offset))
  | 3 ->
      let* offset = decode_byte_offset reader in
      Ok (Csi_discard offset)
  | 4 ->
      let* payload = wire_read Wire.read_string reader in
      let* () = validate_control_bytes ~policy ~field:"osc payload" (String.length payload) in
      let* offset = decode_byte_offset reader in
      Ok (Osc (payload, offset))
  | 5 ->
      let* payload = wire_read Wire.read_string reader in
      let* () = validate_control_bytes ~policy ~field:"osc payload" (String.length payload) in
      let* offset = decode_byte_offset reader in
      Ok (Osc_escape (payload, offset))
  | 6 ->
      let* offset = decode_byte_offset reader in
      Ok (Discard_osc offset)
  | 7 ->
      let* offset = decode_byte_offset reader in
      Ok (Discard_osc_escape offset)
  | 8 ->
      let* kind = decode_control_string reader in
      let* offset = decode_byte_offset reader in
      Ok (Discard_string (kind, offset))
  | 9 ->
      let* kind = decode_control_string reader in
      let* offset = decode_byte_offset reader in
      Ok (Discard_string_escape (kind, offset))
  | _ -> CE.fail (`Malformed "parser tag")

let encode_continuation buffer (continuation : continuation) =
  encode_byte_offset buffer continuation.byte_offset;
  encode_diagnostics_left buffer continuation.diagnostics_left;
  encode_parser buffer continuation.parser;
  encode_utf8 buffer continuation.utf8;
  encode_utf8_bytes buffer continuation.utf8_bytes

let decode_continuation reader ~policy =
  let* byte_offset = decode_byte_offset reader in
  let* diagnostics_left = decode_diagnostics_left reader ~policy in
  let* parser = decode_parser reader ~policy in
  let* utf8 = decode_utf8 reader ~policy in
  let* utf8_bytes = decode_utf8_bytes reader in
  Ok { byte_offset; diagnostics_left; parser; utf8; utf8_bytes }
