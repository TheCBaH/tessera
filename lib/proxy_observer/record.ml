type sequence = int

let pp_sequence = Format.pp_print_int
let compare_sequence = Int.compare
let initial_sequence = 0
let next_sequence sequence = sequence + 1
let sequence_to_int sequence = sequence

let sequence_of_int n =
  if n < 0 then invalid_arg "Record.sequence_of_int: n must be non-negative";
  n

module Pixels = struct
  type pixel_unit = Device_pixels | Css_pixels | Unspecified
  type t = { width : int; height : int; unit : pixel_unit }

  let pp_pixel_unit ppf = function
    | Device_pixels -> Format.pp_print_string ppf "device-pixels"
    | Css_pixels -> Format.pp_print_string ppf "css-pixels"
    | Unspecified -> Format.pp_print_string ppf "unspecified-unit"

  let pp ppf { width; height; unit } = Format.fprintf ppf "%dx%d(%a)" width height pp_pixel_unit unit
end

type traffic = { sequence : sequence; direction : Tessera_foundation.Types.direction; bytes : Bytes.t }
type resize = { sequence : sequence; size : Tessera_foundation.Types.Size.t; pixels : Pixels.t option }
type effect_observation = { sequence : sequence; item : Tessera.Effect.observation }
type t = Traffic of traffic | Resize of resize | Effect of effect_observation

let traffic ~sequence ~direction ~bytes = Traffic { sequence; direction; bytes }
let resize ~sequence ~size ~pixels = Resize { sequence; size; pixels }
let effect_observation ~sequence ~item = Effect { sequence; item }
let sequence = function Traffic { sequence; _ } | Resize { sequence; _ } | Effect { sequence; _ } -> sequence

let pp ppf = function
  | Traffic { sequence; direction; bytes } ->
      Format.fprintf ppf "traffic(#%a, %a, %d byte(s))" pp_sequence sequence Tessera_foundation.Types.pp_direction
        direction (Bytes.length bytes)
  | Resize { sequence; size; pixels } -> (
      match pixels with
      | None -> Format.fprintf ppf "resize(#%a, %a)" pp_sequence sequence Tessera_foundation.Types.Size.pp size
      | Some pixels ->
          Format.fprintf ppf "resize(#%a, %a, %a)" pp_sequence sequence Tessera_foundation.Types.Size.pp size Pixels.pp
            pixels)
  | Effect { sequence; item } ->
      Format.fprintf ppf "effect(#%a, %a)" pp_sequence sequence Tessera_model.Effect.pp_observation item
