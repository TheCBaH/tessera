type capability =
  | Clear_screen
  | Cursor_address
  | Cursor_down
  | Cursor_left
  | Cursor_right
  | Cursor_up
  | Erase_char
  | Erase_line
  | Set_title

type error = [ `Capability_conflict | `Invalid_capability ]
type extension_value = Boolean | Cancelled | Number of int | String of string

let pp_capability ppf = function
  | Clear_screen -> Format.pp_print_string ppf "clear-screen"
  | Cursor_address -> Format.pp_print_string ppf "cursor-address"
  | Cursor_down -> Format.pp_print_string ppf "cursor-down"
  | Cursor_left -> Format.pp_print_string ppf "cursor-left"
  | Cursor_right -> Format.pp_print_string ppf "cursor-right"
  | Cursor_up -> Format.pp_print_string ppf "cursor-up"
  | Erase_char -> Format.pp_print_string ppf "erase-char"
  | Erase_line -> Format.pp_print_string ppf "erase-line"
  | Set_title -> Format.pp_print_string ppf "set-title"

let pp_error ppf = function
  | `Capability_conflict -> Format.pp_print_string ppf "capability conflict"
  | `Invalid_capability -> Format.pp_print_string ppf "invalid capability"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

module Capability_map = struct
  type t = (capability * string) list

  let compare left right = Stdlib.compare left right
  let empty = []
  let find value capability = Option.map snd (List.find_opt (fun (current, _) -> current = capability) value)

  let rec insert value = function
    | [] -> Ok [ value ]
    | ((capability, program) as current) :: rest ->
        let ordering = compare (fst value) capability in
        if ordering = 0 then if snd value = program then Ok (current :: rest) else E.fail `Capability_conflict
        else if ordering < 0 then Ok (value :: current :: rest)
        else Result.map (fun rest -> current :: rest) (insert value rest)

  let of_list values = List.fold_left (fun result value -> Result.bind result (insert value)) (Ok empty) values
  let merge ~earlier ~later = List.fold_left (fun result value -> Result.bind result (insert value)) (Ok earlier) later
  let remove value capability = List.filter (fun (current, _) -> current <> capability) value

  let rec replace ((capability, _) as value) = function
    | [] -> [ value ]
    | ((current, _) as entry) :: rest ->
        let ordering = compare capability current in
        if ordering = 0 then value :: rest
        else if ordering < 0 then value :: entry :: rest
        else entry :: replace value rest

  let override ~base ~overrides = List.fold_left (fun result value -> replace value result) base overrides

  let pp ppf value =
    let pp_entry ppf (capability, program) = Format.fprintf ppf "%a=%S" pp_capability capability program in
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_entry)
      value
end

type t = {
  capabilities : Capability_map.t;
  extensions : (string * extension_value) list;
  names : string list;
  uses : string list;
}

let capabilities value = value.capabilities
let extensions value = value.extensions
let identity value = match value.names with [] -> None | first :: _ -> Some first
let names value = value.names
let uses value = value.uses

let pp_extension_value ppf = function
  | Boolean -> Format.pp_print_string ppf "boolean"
  | Cancelled -> Format.pp_print_string ppf "cancelled"
  | Number value -> Format.fprintf ppf "number(%d)" value
  | String value -> Format.fprintf ppf "string(%S)" value

let capability_of_name = function
  | "clear" -> Some Clear_screen
  | "cup" -> Some Cursor_address
  | "cud1" -> Some Cursor_down
  | "cub1" -> Some Cursor_left
  | "cuf1" -> Some Cursor_right
  | "cuu1" -> Some Cursor_up
  | "ech" -> Some Erase_char
  | "el" -> Some Erase_line
  | "tsl" -> Some Set_title
  | _ -> None

let make ~capabilities = { capabilities; extensions = []; names = []; uses = [] }
let make_with_uses ~capabilities ~uses = { capabilities; extensions = []; names = []; uses }
let make_with_source ~capabilities ~extensions ~names ~uses = { capabilities; extensions; names; uses }
let pp ppf value = Format.fprintf ppf "description(capabilities=%a)" Capability_map.pp value.capabilities
