type t = UInt64.t

let zero = match UInt64.of_int64 0L with Ok value -> value | Error _ -> assert false

let add value increment =
  match UInt64.of_int64 (Int64.of_int (UInt.to_int increment)) with
  | Ok increment -> UInt64.add value increment
  | Error _ as error -> error

let compare = UInt64.compare
let equal = UInt64.equal
let pp = UInt64.pp
