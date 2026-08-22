type capability =
  | Clear_screen
  | Cursor_address
  | Cursor_down
  | Cursor_left
  | Cursor_right
  | Cursor_up
  | Erase_char
  | Erase_line
  | Set_title

type error = [ `Capability_conflict | `Invalid_capability ]
type t
type extension_value = Boolean | Cancelled | Number of int | String of string

module E : Err.S with type error = error

module Capability_map : sig
  type t

  val empty : t
  val find : t -> capability -> string option
  val merge : earlier:t -> later:t -> (t, error) Err.t
  val of_list : (capability * string) list -> (t, error) Err.t
  val override : base:t -> overrides:t -> t
  val pp : Format.formatter -> t -> unit
  val remove : t -> capability -> t
end

val capabilities : t -> Capability_map.t
val capability_of_name : string -> capability option
val extensions : t -> (string * extension_value) list
val make : capabilities:Capability_map.t -> t

val make_with_source :
  capabilities:Capability_map.t ->
  extensions:(string * extension_value) list ->
  names:string list ->
  uses:string list ->
  t

val make_with_uses : capabilities:Capability_map.t -> uses:string list -> t
val names : t -> string list
val pp : Format.formatter -> t -> unit
val pp_capability : Format.formatter -> capability -> unit
val pp_error : Format.formatter -> error -> unit
val pp_extension_value : Format.formatter -> extension_value -> unit
val uses : t -> string list
