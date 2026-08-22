module Palette_index : sig
  type t

  val of_int : int -> t option
  val pp : Format.formatter -> t -> unit
  val to_int : t -> int
end

module Rgb : sig
  type t

  val make : red:int -> green:int -> blue:int -> t option
  val pp : Format.formatter -> t -> unit
end

type color = Default | Indexed of Palette_index.t | Rgb of Rgb.t

type rendition = {
  bold : bool;
  faint : bool;
  invisible : bool;
  inverse : bool;
  italic : bool;
  strikethrough : bool;
  underline : bool;
}

type t = { background : color; foreground : color; rendition : rendition }
type 'a field = Keep | Set of 'a

type delta = {
  background : color field;
  bold : bool field;
  faint : bool field;
  foreground : color field;
  invisible : bool field;
  inverse : bool field;
  italic : bool field;
  strikethrough : bool field;
  underline : bool field;
}

val apply_delta : t -> delta -> t
val compose_delta : earlier:delta -> later:delta -> delta
val default : t
val empty_delta : delta
val indexed_color_delta : foreground:bool -> int -> delta option
val reset_delta : delta
val rgb_color_delta : foreground:bool -> red:int -> green:int -> blue:int -> delta option
val sgr_delta : int -> delta option
val pp : Format.formatter -> t -> unit
val pp_color : Format.formatter -> color -> unit
val pp_delta : Format.formatter -> delta -> unit
val set : 'a -> 'a field
