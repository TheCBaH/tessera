module Description = Description
module Update = Tessera_model.Update
module Types = Tessera_foundation.Types
module UInt = Tessera_foundation.UInt

let ( let* ) = Result.bind

type byte_chunks = Types.slice list
type error = [ `Unexpressible_update of Update.t ]

let pp_error ppf = function
  | `Unexpressible_update update -> Format.fprintf ppf "unexpressible update: %a" Update.pp update

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let program description capability update =
  let* source =
    E.map_none ~pos:__POS__
      ~error:(fun () -> `Unexpressible_update update)
      (Description.Capability_map.find (Description.capabilities description) capability)
  in
  E.map_none ~pos:__POS__ ~error:(fun () -> `Unexpressible_update update) (Capability_program.compile source)

let chunk update text =
  let* off = E.map_error ~pos:__POS__ (fun _ -> `Unexpressible_update update) (UInt.of_int 0) in
  let* length = E.map_error ~pos:__POS__ (fun _ -> `Unexpressible_update update) (UInt.of_int (String.length text)) in
  E.map_error ~pos:__POS__ (fun _ -> `Unexpressible_update update) (Types.slice (Bytes.of_string text) ~off ~len:length)

let sequence ~maximum update program parameters =
  let* text =
    E.map_none ~pos:__POS__
      ~error:(fun () -> `Unexpressible_update update)
      (Capability_program.execute program parameters)
  in
  if String.length text > maximum then E.fail ~pos:__POS__ (`Unexpressible_update update) else chunk update text

let repeat ~maximum update program count =
  let rec loop remaining used chunks =
    if remaining = 0 then Ok (List.rev chunks)
    else
      let* value = sequence ~maximum update program [] in
      let length = UInt.to_int (Types.slice_len value) in
      if length = 0 || used > maximum - length then E.fail ~pos:__POS__ (`Unexpressible_update update)
      else loop (remaining - 1) (used + length) (value :: chunks)
  in
  loop (UInt.to_int count) 0 []

let operation description policy update =
  let maximum = UInt.to_int (Tessera_foundation.Limits.max_control_bytes (Tessera_foundation.Policy.limits policy)) in
  let static capability =
    let* program = program description capability update in
    sequence ~maximum update program []
  in
  let repeated capability count =
    let* program = program description capability update in
    repeat ~maximum update program count
  in
  match update with
  | Update.Reset ->
      let* chunk = static Description.Clear_screen in
      Ok [ chunk ]
  | Update.Erase (Update.Display `Clear_all) ->
      let* chunk = static Description.Clear_screen in
      Ok [ chunk ]
  | Update.Erase (Update.Line `Clear_right) ->
      let* chunk = static Description.Erase_line in
      Ok [ chunk ]
  | Update.Edit (Update.Erase_chars count) ->
      let* program = program description Description.Erase_char update in
      let* chunk = sequence ~maximum update program [ UInt.to_int count ] in
      Ok [ chunk ]
  | Update.Move_cursor (Update.Position { column; row }) ->
      let* program = program description Description.Cursor_address update in
      let* chunk =
        sequence ~maximum update program
          [ UInt.to_int (Types.Row.to_uint row); UInt.to_int (Types.Column.to_uint column) ]
      in
      Ok [ chunk ]
  | Update.Move_cursor (Update.Up count) -> repeated Description.Cursor_up count
  | Update.Move_cursor (Update.Down count) -> repeated Description.Cursor_down count
  | Update.Move_cursor (Update.Back count) -> repeated Description.Cursor_left count
  | Update.Move_cursor (Update.Forward count) -> repeated Description.Cursor_right count
  | Update.Print graphemes ->
      let* chunk = chunk update (Tessera_model.Unicode.Grapheme_sequence.utf8 graphemes) in
      Ok [ chunk ]
  | _ -> E.fail ~pos:__POS__ (`Unexpressible_update update)

let encode description policy batch =
  let chunks =
    Update.Batch.fold_left
      (fun result update ->
        let* chunks = result in
        let* current = operation description policy update in
        Ok (List.rev_append current chunks))
      (Ok []) batch
  in
  Result.map List.rev chunks

let fold_chunks f initial chunks = List.fold_left f initial chunks

let pp_chunk ppf slice =
  let bytes = Types.slice_bytes slice in
  Format.fprintf ppf "%S"
    (Bytes.sub_string bytes (UInt.to_int (Types.slice_off slice)) (UInt.to_int (Types.slice_len slice)))

let pp_byte_chunks ppf chunks =
  Format.fprintf ppf "[%a]"
    (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_chunk)
    chunks
