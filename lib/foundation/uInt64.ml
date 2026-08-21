type t = int64
type error = [ `Negative of int64 | `Overflow ]

let pp_error ppf = function
  | `Negative value -> Format.fprintf ppf "negative(%Ld)" value
  | `Overflow -> Format.pp_print_string ppf "overflow"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let compare = Int64.compare
let equal left right = compare left right = 0
let to_int64 value = value
let pp ppf value = Format.fprintf ppf "%Ld" value
let of_int64 value = if Int64.compare value 0L < 0 then E.fail (`Negative value) else Ok value

let add left right =
  let result = Int64.add left right in
  if Int64.compare result left < 0 then E.fail `Overflow else Ok result

let succ value = add value 1L
