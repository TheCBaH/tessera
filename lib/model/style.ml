module Palette_index = struct
  type t = int

  let of_int value = if value >= 0 && value <= 255 then Some value else None
  let to_int value = value
  let pp ppf value = Format.fprintf ppf "%d" value
end

module Rgb = struct
  type t = { blue : int; green : int; red : int }

  let make ~red ~green ~blue =
    if List.for_all (fun value -> value >= 0 && value <= 255) [ red; green; blue ] then Some { blue; green; red }
    else None

  let pp ppf { blue; green; red } = Format.fprintf ppf "(%d,%d,%d)" red green blue
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

let set value = Set value

let default_rendition =
  {
    bold = false;
    faint = false;
    invisible = false;
    inverse = false;
    italic = false;
    strikethrough = false;
    underline = false;
  }

let default = { background = Default; foreground = Default; rendition = default_rendition }

let empty_delta =
  {
    background = Keep;
    bold = Keep;
    faint = Keep;
    foreground = Keep;
    invisible = Keep;
    inverse = Keep;
    italic = Keep;
    strikethrough = Keep;
    underline = Keep;
  }

let select (old : 'a) (field : 'a field) = match field with Keep -> old | Set value -> value

let apply_delta (style : t) (delta : delta) : t =
  {
    background = select style.background delta.background;
    foreground = select style.foreground delta.foreground;
    rendition =
      {
        bold = select style.rendition.bold delta.bold;
        faint = select style.rendition.faint delta.faint;
        invisible = select style.rendition.invisible delta.invisible;
        inverse = select style.rendition.inverse delta.inverse;
        italic = select style.rendition.italic delta.italic;
        strikethrough = select style.rendition.strikethrough delta.strikethrough;
        underline = select style.rendition.underline delta.underline;
      };
  }

let compose (earlier : 'a field) (later : 'a field) = match later with Keep -> earlier | Set _ -> later

let compose_delta ~earlier ~later =
  {
    background = compose earlier.background later.background;
    bold = compose earlier.bold later.bold;
    faint = compose earlier.faint later.faint;
    foreground = compose earlier.foreground later.foreground;
    invisible = compose earlier.invisible later.invisible;
    inverse = compose earlier.inverse later.inverse;
    italic = compose earlier.italic later.italic;
    strikethrough = compose earlier.strikethrough later.strikethrough;
    underline = compose earlier.underline later.underline;
  }

let pp_color ppf = function
  | Default -> Format.pp_print_string ppf "default"
  | Indexed value -> Format.fprintf ppf "indexed(%a)" Palette_index.pp value
  | Rgb value -> Format.fprintf ppf "rgb%a" Rgb.pp value

let pp_bool_field name ppf = function
  | Keep -> Format.fprintf ppf "%s=keep" name
  | Set value -> Format.fprintf ppf "%s=%b" name value

let pp_color_field name ppf = function
  | Keep -> Format.fprintf ppf "%s=keep" name
  | Set value -> Format.fprintf ppf "%s=%a" name pp_color value

let pp_delta ppf (value : delta) =
  Format.fprintf ppf "{ %a; %a; %a; %a; %a; %a; %a; %a; %a }" (pp_color_field "background") value.background
    (pp_bool_field "bold") value.bold (pp_bool_field "faint") value.faint (pp_color_field "foreground") value.foreground
    (pp_bool_field "invisible") value.invisible (pp_bool_field "inverse") value.inverse (pp_bool_field "italic")
    value.italic (pp_bool_field "strikethrough") value.strikethrough (pp_bool_field "underline") value.underline

let pp ppf ({ background; foreground; rendition } : t) =
  Format.fprintf ppf
    "{background=%a; foreground=%a; bold=%b; faint=%b; invisible=%b; inverse=%b; italic=%b; strikethrough=%b; \
     underline=%b}"
    pp_color background pp_color foreground rendition.bold rendition.faint rendition.invisible rendition.inverse
    rendition.italic rendition.strikethrough rendition.underline
