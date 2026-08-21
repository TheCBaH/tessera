type scalar = Uchar.t
type grapheme = scalar list
type decoder_continuation = grapheme option
type error = [ `Invalid_utf8 | `Unicode_limit_exceeded ]
type width = One | Two | Zero

let pp_error ppf = function
  | `Invalid_utf8 -> Format.pp_print_string ppf "invalid UTF-8"
  | `Unicode_limit_exceeded -> Format.pp_print_string ppf "unicode limit exceeded"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let pp_scalar ppf scalar = Format.fprintf ppf "U+%04X" (Uchar.to_int scalar)

let pp_grapheme ppf grapheme =
  Format.fprintf ppf "<%a>" (Format.pp_print_list ~pp_sep:(fun _ () -> ()) pp_scalar) grapheme

module Grapheme_sequence = struct
  type t = grapheme list

  let empty = []
  let append = ( @ )
  let fold_left = List.fold_left
  let singleton value = [ value ]

  let pp ppf value =
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_grapheme)
      value
end

let initial = None
let is_combining scalar = Uchar.to_int scalar >= 0x300 && Uchar.to_int scalar <= 0x36f
let grapheme_of_scalar scalar = [ scalar ]

let feed _policy pending scalar =
  match (pending, is_combining scalar) with
  | Some grapheme, true -> Ok (Some (grapheme @ [ scalar ]), Grapheme_sequence.empty)
  | Some grapheme, false -> Ok (Some [ scalar ], Grapheme_sequence.singleton grapheme)
  | None, _ -> Ok (Some [ scalar ], Grapheme_sequence.empty)

let finish _policy = function
  | None -> Ok Grapheme_sequence.empty
  | Some grapheme -> Ok (Grapheme_sequence.singleton grapheme)

let pp_decoder_continuation ppf = function
  | None -> Format.pp_print_string ppf "empty"
  | Some grapheme -> Format.fprintf ppf "pending(%a)" pp_grapheme grapheme

let pp_width ppf = function
  | One -> Format.pp_print_string ppf "one"
  | Two -> Format.pp_print_string ppf "two"
  | Zero -> Format.pp_print_string ppf "zero"

let width grapheme =
  match grapheme with
  | [] -> Zero
  | first :: _ ->
      let value = Uchar.to_int first in
      if is_combining first then Zero
      else if
        (value >= 0x1100 && value <= 0x115f)
        || (value >= 0x2e80 && value <= 0xa4cf)
        || (value >= 0xac00 && value <= 0xd7a3)
        || (value >= 0xf900 && value <= 0xfaff)
        || value >= 0x1f300
      then Two
      else One
