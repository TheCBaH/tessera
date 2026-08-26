module Foundation = Tessera_foundation

type pixel_unit = Device_pixels | Css_pixels | Unspecified
type pixels = { width : int; height : int; unit : pixel_unit }
type t = { columns : Foundation.UInt.t; rows : Foundation.UInt.t; pixels : pixels option }

let make ~columns ~rows ~pixels = { columns; rows; pixels }
let columns t = t.columns
let rows t = t.rows
let pixels t = t.pixels
let size t = Foundation.Types.Size.make ~columns:t.columns ~rows:t.rows

let same_geometry left right =
  Foundation.UInt.equal left.columns right.columns && Foundation.UInt.equal left.rows right.rows

let pp_pixel_unit ppf = function
  | Device_pixels -> Format.pp_print_string ppf "device-pixels"
  | Css_pixels -> Format.pp_print_string ppf "css-pixels"
  | Unspecified -> Format.pp_print_string ppf "unspecified-unit"

let pp_pixels ppf { width; height; unit } = Format.fprintf ppf "%dx%d(%a)" width height pp_pixel_unit unit

let pp ppf { columns; rows; pixels } =
  match pixels with
  | None -> Format.fprintf ppf "%a×%a" Foundation.UInt.pp columns Foundation.UInt.pp rows
  | Some pixels -> Format.fprintf ppf "%a×%a[%a]" Foundation.UInt.pp columns Foundation.UInt.pp rows pp_pixels pixels
