type tag
type t = tag Id.t

let compare = Id.compare
let equal = Id.equal
let pp = Id.pp
let zero = match UInt.of_int 0 with Ok value -> Id.of_uint value | Error _ -> assert false
let succ value = Id.succ value
