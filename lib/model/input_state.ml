type mouse_tracking = Off | X10 | Button_event | Any_event
type mouse_encoding = Default | Utf8 | Sgr | Urxvt
type 'a field = Keep | Set of 'a

type t = {
  application_cursor : bool;
  application_keypad : bool;
  bracketed_paste : bool;
  focus_reporting : bool;
  mouse_tracking : mouse_tracking;
  mouse_encoding : mouse_encoding;
}

type delta = {
  application_cursor : bool field;
  application_keypad : bool field;
  bracketed_paste : bool field;
  focus_reporting : bool field;
  mouse_tracking : mouse_tracking field;
  mouse_encoding : mouse_encoding field;
}

type view = {
  application_cursor : bool;
  application_keypad : bool;
  bracketed_paste : bool;
  focus_reporting : bool;
  mouse_tracking : mouse_tracking;
  mouse_encoding : mouse_encoding;
}

let default : t =
  {
    application_cursor = false;
    application_keypad = false;
    bracketed_paste = false;
    focus_reporting = false;
    mouse_tracking = Off;
    mouse_encoding = Default;
  }

let empty_delta : delta =
  {
    application_cursor = Keep;
    application_keypad = Keep;
    bracketed_paste = Keep;
    focus_reporting = Keep;
    mouse_tracking = Keep;
    mouse_encoding = Keep;
  }

let select (current : 'a) (field : 'a field) = match field with Keep -> current | Set value -> value

let apply_delta (current : t) (delta : delta) =
  ({
     application_cursor = select current.application_cursor delta.application_cursor;
     application_keypad = select current.application_keypad delta.application_keypad;
     bracketed_paste = select current.bracketed_paste delta.bracketed_paste;
     focus_reporting = select current.focus_reporting delta.focus_reporting;
     mouse_tracking = select current.mouse_tracking delta.mouse_tracking;
     mouse_encoding = select current.mouse_encoding delta.mouse_encoding;
   }
    : t)

let compose (earlier : 'a field) (later : 'a field) = match later with Keep -> earlier | Set _ -> later

let compose_delta ~(earlier : delta) ~(later : delta) =
  ({
     application_cursor = compose earlier.application_cursor later.application_cursor;
     application_keypad = compose earlier.application_keypad later.application_keypad;
     bracketed_paste = compose earlier.bracketed_paste later.bracketed_paste;
     focus_reporting = compose earlier.focus_reporting later.focus_reporting;
     mouse_tracking = compose earlier.mouse_tracking later.mouse_tracking;
     mouse_encoding = compose earlier.mouse_encoding later.mouse_encoding;
   }
    : delta)

let keypad_delta ~enabled = { empty_delta with application_keypad = Set enabled }

let private_mode_delta ~enabled = function
  | 1 -> Some { empty_delta with application_cursor = Set enabled }
  | 1000 -> Some { empty_delta with mouse_tracking = Set (if enabled then X10 else Off) }
  | 1002 -> Some { empty_delta with mouse_tracking = Set (if enabled then Button_event else Off) }
  | 1003 -> Some { empty_delta with mouse_tracking = Set (if enabled then Any_event else Off) }
  | 1004 -> Some { empty_delta with focus_reporting = Set enabled }
  | 1005 -> Some { empty_delta with mouse_encoding = Set (if enabled then Utf8 else Default) }
  | 1006 -> Some { empty_delta with mouse_encoding = Set (if enabled then Sgr else Default) }
  | 1015 -> Some { empty_delta with mouse_encoding = Set (if enabled then Urxvt else Default) }
  | 2004 -> Some { empty_delta with bracketed_paste = Set enabled }
  | _ -> None

let view (value : t) =
  {
    application_cursor = value.application_cursor;
    application_keypad = value.application_keypad;
    bracketed_paste = value.bracketed_paste;
    focus_reporting = value.focus_reporting;
    mouse_tracking = value.mouse_tracking;
    mouse_encoding = value.mouse_encoding;
  }

let pp_tracking ppf = function
  | Off -> Format.pp_print_string ppf "off"
  | X10 -> Format.pp_print_string ppf "x10"
  | Button_event -> Format.pp_print_string ppf "button-event"
  | Any_event -> Format.pp_print_string ppf "any-event"

let pp_encoding ppf = function
  | Default -> Format.pp_print_string ppf "default"
  | Utf8 -> Format.pp_print_string ppf "utf8"
  | Sgr -> Format.pp_print_string ppf "sgr"
  | Urxvt -> Format.pp_print_string ppf "urxvt"

let pp ppf (value : t) =
  Format.fprintf ppf
    "{application_cursor=%b; application_keypad=%b; bracketed_paste=%b; focus_reporting=%b; mouse_tracking=%a; \
     mouse_encoding=%a}"
    value.application_cursor value.application_keypad value.bracketed_paste value.focus_reporting pp_tracking
    value.mouse_tracking pp_encoding value.mouse_encoding

let pp_delta ppf _ = Format.pp_print_string ppf "input-state-delta"
