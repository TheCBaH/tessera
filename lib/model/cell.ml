type contents = Empty | Glyph of Unicode.grapheme | Wide_continuation
type t = { contents : contents; line_id : Tessera_foundation.Line_id.t; style : Style.t }

let blank ~line_id ~style = { contents = Empty; line_id; style }
let glyph ~line_id ~style grapheme = { contents = Glyph grapheme; line_id; style }
let wide_continuation ~line_id ~style = { contents = Wide_continuation; line_id; style }
let contents value = value.contents
let line_id value = value.line_id
let style value = value.style

let pp_contents ppf = function
  | Empty -> Format.pp_print_string ppf "empty"
  | Glyph grapheme -> Format.fprintf ppf "glyph(%a)" Unicode.pp_grapheme grapheme
  | Wide_continuation -> Format.pp_print_string ppf "wide-continuation"

let pp ppf { contents; line_id; style } =
  Format.fprintf ppf "{contents=%a; line_id=%a; style=%a}" pp_contents contents Tessera_foundation.Line_id.pp line_id
    Style.pp style
