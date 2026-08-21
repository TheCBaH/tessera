open Tessera_foundation
module Unicode = Tessera_model.Unicode
module Effect = Tessera_model.Effect
module Update = Tessera_model.Update

type continuation = { utf8 : Unicode.decoder_continuation }
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

let initial = { utf8 = Unicode.initial }
let pp ppf _ = Format.pp_print_string ppf "decoder-continuation"

let pp_decoded ppf value =
  Format.fprintf ppf "{continuation=%a; items=%a}" pp value.continuation Effect.Item_sequence.pp value.items

let item update = Effect.Item_sequence.singleton (Effect.Update update)

let feed policy continuation slice =
  let bytes = Types.slice_bytes slice
  and start = UInt.to_int (Types.slice_off slice)
  and length = UInt.to_int (Types.slice_len slice) in
  let utf8 = ref continuation.utf8 and items = ref Effect.Item_sequence.empty in
  let emit update = items := Effect.Item_sequence.append !items (item update) in
  let scalar value =
    match Unicode.feed policy !utf8 (Uchar.of_int value) with
    | Ok (next, graphemes) ->
        utf8 := next;
        if graphemes <> Unicode.Grapheme_sequence.empty then emit (Update.Print graphemes)
    | Error error -> raise (Invalid_argument (Format.asprintf "%a" Unicode.pp_error (Err.Error.kind error)))
  in
  try
    for index = start to start + length - 1 do
      match Char.code (Bytes.get bytes index) with
      | 8 -> emit Update.Backspace
      | 9 -> emit Update.Horizontal_tab
      | 10 | 11 | 12 -> emit Update.Line_feed
      | 13 -> emit Update.Carriage_return
      | value when value >= 32 && value < 127 -> scalar value
      | _ -> ()
    done;
    Ok { continuation = { utf8 = !utf8 }; items = !items }
  with Invalid_argument _ -> E.fail (`Internal_invariant "unicode continuation")

let finish policy continuation =
  match Unicode.finish policy continuation.utf8 with
  | Ok graphemes ->
      Ok
        {
          continuation = initial;
          items =
            (if graphemes = Unicode.Grapheme_sequence.empty then Effect.Item_sequence.empty
             else item (Update.Print graphemes));
        }
  | Error error -> E.fail (`Unicode (Err.Error.kind error))
