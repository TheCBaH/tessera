type diagnostic =
  | Control_string_too_long of { kind : string; offset : Tessera_foundation.Byte_offset.t }
  | Invalid_utf8 of { offset : Tessera_foundation.Byte_offset.t }
  | Malformed_csi of { offset : Tessera_foundation.Byte_offset.t; reason : string }
  | Unsupported_sequence of { family : string; offset : Tessera_foundation.Byte_offset.t }

type item = Observation of diagnostic | Update of Update.t

let pp_diagnostic ppf = function
  | Control_string_too_long { kind; offset } ->
      Format.fprintf ppf "control-string-too-long(kind=%S; offset=%a)" kind Tessera_foundation.Byte_offset.pp offset
  | Invalid_utf8 { offset } -> Format.fprintf ppf "invalid-utf8(offset=%a)" Tessera_foundation.Byte_offset.pp offset
  | Malformed_csi { offset; reason } ->
      Format.fprintf ppf "malformed-csi(offset=%a; reason=%S)" Tessera_foundation.Byte_offset.pp offset reason
  | Unsupported_sequence { family; offset } ->
      Format.fprintf ppf "unsupported-sequence(family=%S; offset=%a)" family Tessera_foundation.Byte_offset.pp offset

let pp_item ppf = function
  | Observation value -> Format.fprintf ppf "observation(%a)" pp_diagnostic value
  | Update value -> Format.fprintf ppf "update(%a)" Update.pp value

module Item_sequence = struct
  type nonrec t = item list

  let empty = []
  let singleton value = [ value ]
  let append = ( @ )
  let fold_left = List.fold_left

  let pp ppf value =
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_item)
      value
end

module Observation_sequence = struct
  type t = diagnostic list

  let empty = []
  let singleton value = [ value ]
  let append = ( @ )

  let pp ppf value =
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_diagnostic)
      value
end
