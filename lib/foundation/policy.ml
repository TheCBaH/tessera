type profile = Xterm_256color_core
type t = { limits : Limits.t; profile : profile }

let make ~limits ~profile = { limits; profile }
let limits value = value.limits
let profile value = value.profile
let pp_profile ppf Xterm_256color_core = Format.pp_print_string ppf "xterm-256color-core"
let pp ppf { limits; profile } = Format.fprintf ppf "{limits=%a; profile=%a}" Limits.pp limits pp_profile profile
