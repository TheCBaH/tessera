(** Authoritative application-controlled input modes. This is intentionally separate from rendering modes: it describes
    how a controller must encode browser input, not how a screen is painted. *)

type mouse_tracking = Off | X10 | Button_event | Any_event
type mouse_encoding = Default | Utf8 | Sgr | Urxvt
type t
type delta

type view = {
  application_cursor : bool;
  application_keypad : bool;
  bracketed_paste : bool;
  focus_reporting : bool;
  mouse_tracking : mouse_tracking;
  mouse_encoding : mouse_encoding;
}

val default : t
val apply_delta : t -> delta -> t
val compose_delta : earlier:delta -> later:delta -> delta
val empty_delta : delta
val keypad_delta : enabled:bool -> delta
val private_mode_delta : enabled:bool -> int -> delta option
val view : t -> view
val pp : Format.formatter -> t -> unit
val pp_delta : Format.formatter -> delta -> unit
