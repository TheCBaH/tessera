type error = [ `Invalid_rect | `Invalid_size | `Invalid_slice ]

let pp_error ppf = function
  | `Invalid_rect -> Format.pp_print_string ppf "invalid rectangle"
  | `Invalid_size -> Format.pp_print_string ppf "invalid size"
  | `Invalid_slice -> Format.pp_print_string ppf "invalid slice"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

module Column = struct
  type t = UInt.t

  let compare = UInt.compare
  let of_uint value = value
  let to_uint value = value
  let pp = UInt.pp
end

module Row = struct
  type t = UInt.t

  let compare = UInt.compare
  let of_uint value = value
  let to_uint value = value
  let pp = UInt.pp
end

type coord = { column : Column.t; row : Row.t }
type rect = { bottom : Row.t; left : Column.t; right : Column.t; top : Row.t }
type screen = Alternate | Primary
type slice = { bytes : bytes; len : UInt.t; off : UInt.t }

module Size = struct
  type t = { columns : UInt.t; rows : UInt.t }

  let zero = match UInt.of_int 0 with Ok value -> value | Error _ -> assert false

  let make ~columns ~rows =
    if UInt.equal columns zero || UInt.equal rows zero then E.fail `Invalid_size else Ok { columns; rows }

  let columns value = value.columns
  let rows value = value.rows

  let contains size { column; row } =
    UInt.compare (Column.to_uint column) size.columns < 0 && UInt.compare (Row.to_uint row) size.rows < 0

  let pp ppf { columns; rows } = Format.fprintf ppf "%a×%a" UInt.pp columns UInt.pp rows
end

let coord ~column ~row = { column; row }
let pp_coord ppf { column; row } = Format.fprintf ppf "(%a,%a)" Column.pp column Row.pp row

let pp_screen ppf = function
  | Alternate -> Format.pp_print_string ppf "alternate"
  | Primary -> Format.pp_print_string ppf "primary"

let pp_rect ppf { bottom; left; right; top } =
  Format.fprintf ppf "{top=%a; left=%a; bottom=%a; right=%a}" Row.pp top Column.pp left Row.pp bottom Column.pp right

let rect ~bottom ~left ~right ~top =
  if Row.compare top bottom > 0 || Column.compare left right > 0 then E.fail `Invalid_rect
  else Ok { bottom; left; right; top }

let slice bytes ~len ~off =
  let length = Bytes.length bytes in
  let offset = UInt.to_int off and requested = UInt.to_int len in
  if offset > length || requested > length - offset then E.fail `Invalid_slice else Ok { bytes; len; off }

let slice_bytes value = value.bytes
let slice_len value = value.len
let slice_off value = value.off
let pp_slice ppf { len; off; _ } = Format.fprintf ppf "slice(off=%a; len=%a)" UInt.pp off UInt.pp len
