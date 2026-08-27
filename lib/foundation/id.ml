type 'kind t = UInt.t

let compare = UInt.compare
let equal = UInt.equal
let pp = UInt.pp
let of_uint value = value
let to_uint value = value
let succ value = UInt.succ value
