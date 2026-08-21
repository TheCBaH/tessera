type t = { auto_wrap : bool; cursor_visible : bool; insert : bool; origin : bool }
type 'a field = Keep | Set of 'a
type delta = { auto_wrap : bool field; cursor_visible : bool field; insert : bool field; origin : bool field }

let set value = Set value
let default : t = { auto_wrap = true; cursor_visible = true; insert = false; origin = false }
let empty_delta : delta = { auto_wrap = Keep; cursor_visible = Keep; insert = Keep; origin = Keep }
let select (old : 'a) (field : 'a field) = match field with Keep -> old | Set value -> value

let apply_delta (mode : t) (delta : delta) : t =
  {
    auto_wrap = select mode.auto_wrap delta.auto_wrap;
    cursor_visible = select mode.cursor_visible delta.cursor_visible;
    insert = select mode.insert delta.insert;
    origin = select mode.origin delta.origin;
  }

let compose (left : 'a field) (right : 'a field) = match right with Keep -> left | Set _ -> right

let compose_delta ~earlier ~later =
  {
    auto_wrap = compose earlier.auto_wrap later.auto_wrap;
    cursor_visible = compose earlier.cursor_visible later.cursor_visible;
    insert = compose earlier.insert later.insert;
    origin = compose earlier.origin later.origin;
  }

let pp ppf (mode : t) =
  Format.fprintf ppf "{auto_wrap=%b; cursor_visible=%b; insert=%b; origin=%b}" mode.auto_wrap mode.cursor_visible
    mode.insert mode.origin

let pp_field name ppf = function
  | Keep -> Format.fprintf ppf "%s=keep" name
  | Set value -> Format.fprintf ppf "%s=%b" name value

let pp_delta ppf (delta : delta) =
  Format.fprintf ppf "{%a; %a; %a; %a}" (pp_field "auto_wrap") delta.auto_wrap (pp_field "cursor_visible")
    delta.cursor_visible (pp_field "insert") delta.insert (pp_field "origin") delta.origin
