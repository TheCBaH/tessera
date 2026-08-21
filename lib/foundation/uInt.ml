type t = int
type error = [ `Negative of int | `Overflow ]

let pp_error ppf = function
  | `Negative value -> Format.fprintf ppf "negative(%d)" value
  | `Overflow -> Format.pp_print_string ppf "overflow"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let max_value = max_int
let compare = Int.compare
let equal left right = compare left right = 0
let to_int value = value
let pp ppf value = Format.fprintf ppf "%d" value
let of_int value = if value < 0 then E.fail (`Negative value) else Ok value
let add left right = if left > max_int - right then E.fail `Overflow else Ok (left + right)
let succ value = add value 1
