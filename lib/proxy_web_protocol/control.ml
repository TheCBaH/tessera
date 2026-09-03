type target = Html | Canvas
type capabilities = { observe : bool; input : bool; resize : bool }

type input_state = {
  generation : string;
  application_cursor : bool;
  application_keypad : bool;
  bracketed_paste : bool;
  focus_reporting : bool;
  mouse_tracking : [ `Off | `X10 | `Button_event | `Any_event ];
  mouse_encoding : [ `Default | `Utf8 | `Sgr | `Urxvt ];
}

type client_message =
  | Hello of { id : string; target : target }
  | Resync of { id : string }
  | Close of { id : string }
  | Acquire_control of { id : string }
  | Release_control of { id : string }
  | Input of { id : string; bytes : bytes }

type server_message =
  | Ready of { id : string; capabilities : capabilities }
  | Input_state of input_state
  | Result of { id : string }
  | Error of { id : string option; message : string }

type error =
  [ `Json of string | `Oversize | `Unknown_schema of string | `Unknown_type of string | `Unknown_version of int ]

let pp_error ppf = function
  | `Json msg -> Format.fprintf ppf "json(%s)" msg
  | `Oversize -> Format.pp_print_string ppf "oversize"
  | `Unknown_schema s -> Format.fprintf ppf "unknown-schema(%s)" s
  | `Unknown_type t -> Format.fprintf ppf "unknown-type(%s)" t
  | `Unknown_version v -> Format.fprintf ppf "unknown-version(%d)" v

module Error_domain = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error_domain)

let schema = "tessera.proxy-web"
let version = 2
let pp_target ppf = function Html -> Format.pp_print_string ppf "html" | Canvas -> Format.pp_print_string ppf "canvas"

let pp_capabilities ppf { observe; input; resize } =
  Format.fprintf ppf "capabilities(observe=%b, input=%b, resize=%b)" observe input resize

let pp_input_state ppf state =
  let pp_tracking ppf = function
    | `Off -> Format.pp_print_string ppf "off"
    | `X10 -> Format.pp_print_string ppf "x10"
    | `Button_event -> Format.pp_print_string ppf "button-event"
    | `Any_event -> Format.pp_print_string ppf "any-event"
  in
  let pp_encoding ppf = function
    | `Default -> Format.pp_print_string ppf "default"
    | `Utf8 -> Format.pp_print_string ppf "utf8"
    | `Sgr -> Format.pp_print_string ppf "sgr"
    | `Urxvt -> Format.pp_print_string ppf "urxvt"
  in
  Format.fprintf ppf "input-state(generation=%s, cursor=%b, keypad=%b, paste=%b, focus=%b, tracking=%a, encoding=%a)"
    state.generation state.application_cursor state.application_keypad state.bracketed_paste state.focus_reporting
    pp_tracking state.mouse_tracking pp_encoding state.mouse_encoding

let pp_client_message ppf = function
  | Hello { id; target } -> Format.fprintf ppf "hello(id=%S, target=%a)" id pp_target target
  | Resync { id } -> Format.fprintf ppf "resync(id=%S)" id
  | Close { id } -> Format.fprintf ppf "close(id=%S)" id
  | Acquire_control { id } -> Format.fprintf ppf "acquire-control(id=%S)" id
  | Release_control { id } -> Format.fprintf ppf "release-control(id=%S)" id
  | Input { id; bytes } -> Format.fprintf ppf "input(id=%S, bytes=%d)" id (Bytes.length bytes)

let pp_server_message ppf = function
  | Ready { id; capabilities } -> Format.fprintf ppf "ready(id=%S, %a)" id pp_capabilities capabilities
  | Input_state state -> pp_input_state ppf state
  | Result { id } -> Format.fprintf ppf "result(id=%S)" id
  | Error { id = None; message } -> Format.fprintf ppf "error(id=none, %S)" message
  | Error { id = Some id; message } -> Format.fprintf ppf "error(id=%S, %S)" id message

let target_jsont =
  Jsont.map Jsont.string
    ~dec:(function "html" -> Html | "canvas" -> Canvas | s -> Jsont.Error.msg Jsont.Meta.none ("invalid target " ^ s))
    ~enc:(function Html -> "html" | Canvas -> "canvas")

let capabilities_jsont =
  Jsont.Object.map (fun observe input resize -> { observe; input; resize })
  |> Jsont.Object.mem "observe" Jsont.bool ~enc:(fun c -> c.observe)
  |> Jsont.Object.mem "input" Jsont.bool ~enc:(fun c -> c.input)
  |> Jsont.Object.mem "resize" Jsont.bool ~enc:(fun c -> c.resize)
  |> Jsont.Object.finish

let canonical_decimal value =
  let length = String.length value in
  length > 0 && String.for_all (fun c -> c >= '0' && c <= '9') value && (value.[0] <> '0' || length = 1)

let mouse_tracking_jsont =
  Jsont.map Jsont.string
    ~dec:(function
      | "off" -> `Off
      | "x10" -> `X10
      | "button-event" -> `Button_event
      | "any-event" -> `Any_event
      | value -> Jsont.Error.msg Jsont.Meta.none ("invalid mouse tracking " ^ value))
    ~enc:(function `Off -> "off" | `X10 -> "x10" | `Button_event -> "button-event" | `Any_event -> "any-event")

let mouse_encoding_jsont =
  Jsont.map Jsont.string
    ~dec:(function
      | "default" -> `Default
      | "utf8" -> `Utf8
      | "sgr" -> `Sgr
      | "urxvt" -> `Urxvt
      | value -> Jsont.Error.msg Jsont.Meta.none ("invalid mouse encoding " ^ value))
    ~enc:(function `Default -> "default" | `Utf8 -> "utf8" | `Sgr -> "sgr" | `Urxvt -> "urxvt")

let input_state_jsont =
  Jsont.Object.map
    (fun
      generation application_cursor application_keypad bracketed_paste focus_reporting mouse_tracking mouse_encoding ->
      if canonical_decimal generation then
        {
          generation;
          application_cursor;
          application_keypad;
          bracketed_paste;
          focus_reporting;
          mouse_tracking;
          mouse_encoding;
        }
      else Jsont.Error.msg Jsont.Meta.none "invalid input-state generation")
  |> Jsont.Object.mem "generation" Jsont.string ~enc:(fun value -> value.generation)
  |> Jsont.Object.mem "application_cursor" Jsont.bool ~enc:(fun value -> value.application_cursor)
  |> Jsont.Object.mem "application_keypad" Jsont.bool ~enc:(fun value -> value.application_keypad)
  |> Jsont.Object.mem "bracketed_paste" Jsont.bool ~enc:(fun value -> value.bracketed_paste)
  |> Jsont.Object.mem "focus_reporting" Jsont.bool ~enc:(fun value -> value.focus_reporting)
  |> Jsont.Object.mem "mouse_tracking" mouse_tracking_jsont ~enc:(fun value -> value.mouse_tracking)
  |> Jsont.Object.mem "mouse_encoding" mouse_encoding_jsont ~enc:(fun value -> value.mouse_encoding)
  |> Jsont.Object.finish

(* Raw client envelope: every field any client message can carry, decoded structurally by Jsont; the
   schema/version/type/field-combination checks below are plain OCaml so an unknown [schema]/[version]/[type] is a
   distinct typed error rather than folded into the generic [`Json] decode-failure case Jsont itself would report for
   a missing/mistyped field. *)
type raw_client = {
  c_schema : string;
  c_version : int;
  c_type : string;
  c_id : string;
  c_target : target option;
  c_bytes_b64 : string option;
}

let raw_client_jsont =
  Jsont.Object.map (fun c_schema c_version c_type c_id c_target c_bytes_b64 ->
      { c_schema; c_version; c_type; c_id; c_target; c_bytes_b64 })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun v -> v.c_schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun v -> v.c_version)
  |> Jsont.Object.mem "type" Jsont.string ~enc:(fun v -> v.c_type)
  |> Jsont.Object.mem "id" Jsont.string ~enc:(fun v -> v.c_id)
  |> Jsont.Object.opt_mem "target" target_jsont ~enc:(fun v -> v.c_target)
  |> Jsont.Object.opt_mem "bytes_b64" Jsont.string ~enc:(fun v -> v.c_bytes_b64)
  |> Jsont.Object.finish

let base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64_encode bytes =
  let length = Bytes.length bytes in
  let output = Bytes.create ((length + 2) / 3 * 4) in
  let emit index value = Bytes.set output index base64_alphabet.[value] in
  let rec loop source target =
    if source >= length then ()
    else begin
      let a = Char.code (Bytes.get bytes source) in
      let b = if source + 1 < length then Char.code (Bytes.get bytes (source + 1)) else 0 in
      let c = if source + 2 < length then Char.code (Bytes.get bytes (source + 2)) else 0 in
      emit target (a lsr 2);
      emit (target + 1) (((a land 0x03) lsl 4) lor (b lsr 4));
      Bytes.set output (target + 2)
        (if source + 1 < length then base64_alphabet.[((b land 0x0f) lsl 2) lor (c lsr 6)] else '=');
      Bytes.set output (target + 3) (if source + 2 < length then base64_alphabet.[c land 0x3f] else '=');
      loop (source + 3) (target + 4)
    end
  in
  loop 0 0;
  Bytes.unsafe_to_string output

let base64_value = function
  | 'A' .. 'Z' as c -> Char.code c - Char.code 'A'
  | 'a' .. 'z' as c -> Char.code c - Char.code 'a' + 26
  | '0' .. '9' as c -> Char.code c - Char.code '0' + 52
  | '+' -> 62
  | '/' -> 63
  | _ -> -1

let base64_decode text =
  let length = String.length text in
  if length = 0 then Stdlib.Result.Error "input bytes_b64 must not be empty"
  else if length mod 4 <> 0 then Stdlib.Result.Error "input bytes_b64 has invalid length"
  else
    let padding = if text.[length - 1] = '=' then if text.[length - 2] = '=' then 2 else 1 else 0 in
    let output = Bytes.create ((length / 4 * 3) - padding) in
    let fail message = Stdlib.Result.Error message in
    let rec loop source target =
      if source = length then Stdlib.Result.Ok output
      else
        let last = source + 4 = length in
        let a = base64_value text.[source] in
        let b = base64_value text.[source + 1] in
        let c = if text.[source + 2] = '=' then -2 else base64_value text.[source + 2] in
        let d = if text.[source + 3] = '=' then -2 else base64_value text.[source + 3] in
        if a < 0 || b < 0 || c = -1 || d = -1 then fail "input bytes_b64 has invalid character"
        else if (c = -2 && ((not last) || d <> -2)) || (d = -2 && not last) then
          fail "input bytes_b64 has invalid padding"
        else if c = -2 && b land 0x0f <> 0 then fail "input bytes_b64 has non-canonical padding"
        else if d = -2 && c >= 0 && c land 0x03 <> 0 then fail "input bytes_b64 has non-canonical padding"
        else begin
          Bytes.set output target (Char.chr ((a lsl 2) lor (b lsr 4)));
          if c >= 0 then Bytes.set output (target + 1) (Char.chr (((b land 0x0f) lsl 4) lor (c lsr 2)));
          if d >= 0 then Bytes.set output (target + 2) (Char.chr (((c land 0x03) lsl 6) lor d));
          loop (source + 4) (target + 3 - if c = -2 then 2 else if d = -2 then 1 else 0)
        end
    in
    loop 0 0

type raw_server = {
  s_schema : string;
  s_version : int;
  s_type : string;
  s_id : string option;
  s_capabilities : capabilities option;
  s_message : string option;
  s_input_state : input_state option;
}

let raw_server_jsont =
  Jsont.Object.map (fun s_schema s_version s_type s_id s_capabilities s_message s_input_state ->
      { s_schema; s_version; s_type; s_id; s_capabilities; s_message; s_input_state })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun v -> v.s_schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun v -> v.s_version)
  |> Jsont.Object.mem "type" Jsont.string ~enc:(fun v -> v.s_type)
  |> Jsont.Object.mem "id" (Jsont.option Jsont.string) ~enc:(fun v -> v.s_id)
  |> Jsont.Object.opt_mem "capabilities" capabilities_jsont ~enc:(fun v -> v.s_capabilities)
  |> Jsont.Object.opt_mem "message" Jsont.string ~enc:(fun v -> v.s_message)
  |> Jsont.Object.opt_mem "input_state" input_state_jsont ~enc:(fun v -> v.s_input_state)
  |> Jsont.Object.finish

let raw_of_client_message = function
  | Hello { id; target } ->
      {
        c_schema = schema;
        c_version = version;
        c_type = "hello";
        c_id = id;
        c_target = Some target;
        c_bytes_b64 = None;
      }
  | Resync { id } ->
      { c_schema = schema; c_version = version; c_type = "resync"; c_id = id; c_target = None; c_bytes_b64 = None }
  | Close { id } ->
      { c_schema = schema; c_version = version; c_type = "close"; c_id = id; c_target = None; c_bytes_b64 = None }
  | Acquire_control { id } ->
      {
        c_schema = schema;
        c_version = version;
        c_type = "acquire_control";
        c_id = id;
        c_target = None;
        c_bytes_b64 = None;
      }
  | Release_control { id } ->
      {
        c_schema = schema;
        c_version = version;
        c_type = "release_control";
        c_id = id;
        c_target = None;
        c_bytes_b64 = None;
      }
  | Input { id; bytes } ->
      {
        c_schema = schema;
        c_version = version;
        c_type = "input";
        c_id = id;
        c_target = None;
        c_bytes_b64 = Some (base64_encode bytes);
      }

let client_message_of_raw (raw : raw_client) : (client_message, error) result =
  if raw.c_schema <> schema then Error (`Unknown_schema raw.c_schema)
  else if raw.c_version <> version then Error (`Unknown_version raw.c_version)
  else
    match (raw.c_type, raw.c_target, raw.c_bytes_b64) with
    | "hello", Some target, None -> Ok (Hello { id = raw.c_id; target })
    | "hello", None, _ -> Error (`Json "hello message missing target")
    | "hello", Some _, Some _ -> Error (`Json "hello message must not carry bytes_b64")
    | ("resync" | "close" | "acquire_control" | "release_control"), None, None ->
        Ok
          (match raw.c_type with
          | "resync" -> Resync { id = raw.c_id }
          | "close" -> Close { id = raw.c_id }
          | "acquire_control" -> Acquire_control { id = raw.c_id }
          | "release_control" -> Release_control { id = raw.c_id }
          | _ -> assert false)
    | ("resync" | "close" | "acquire_control" | "release_control"), _, _ ->
        Error (`Json (raw.c_type ^ " message must not carry target or bytes_b64"))
    | "input", None, Some bytes_b64 -> (
        match base64_decode bytes_b64 with
        | Stdlib.Result.Ok bytes -> Ok (Input { id = raw.c_id; bytes })
        | Stdlib.Result.Error message -> Error (`Json message))
    | "input", Some _, _ -> Error (`Json "input message must not carry target")
    | "input", None, None -> Error (`Json "input message missing bytes_b64")
    | other, _, _ -> Error (`Unknown_type other)

let raw_of_server_message = function
  | Ready { id; capabilities } ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "ready";
        s_id = Some id;
        s_capabilities = Some capabilities;
        s_message = None;
        s_input_state = None;
      }
  | Input_state input_state ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "input_state";
        s_id = None;
        s_capabilities = None;
        s_message = None;
        s_input_state = Some input_state;
      }
  | Result { id } ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "result";
        s_id = Some id;
        s_capabilities = None;
        s_message = None;
        s_input_state = None;
      }
  | Error { id; message } ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "error";
        s_id = id;
        s_capabilities = None;
        s_message = Some message;
        s_input_state = None;
      }

let server_message_of_raw (raw : raw_server) : (server_message, error) result =
  if raw.s_schema <> schema then Error (`Unknown_schema raw.s_schema)
  else if raw.s_version <> version then Error (`Unknown_version raw.s_version)
  else
    match (raw.s_type, raw.s_id, raw.s_capabilities, raw.s_message, raw.s_input_state) with
    | "ready", Some id, Some capabilities, None, None -> Ok (Ready { id; capabilities })
    | "ready", None, _, _, _ -> Error (`Json "ready message must carry a non-null id")
    | "ready", Some _, None, _, _ -> Error (`Json "ready message missing capabilities")
    | "input_state", None, None, None, Some state -> Ok (Input_state state)
    | "input_state", Some _, _, _, _ -> Error (`Json "input_state message must not carry id")
    | "input_state", _, Some _, _, _ -> Error (`Json "input_state message must not carry capabilities")
    | "input_state", _, _, Some _, _ -> Error (`Json "input_state message must not carry message")
    | "input_state", _, _, _, None -> Error (`Json "input_state message missing input_state")
    | "result", Some id, None, None, None -> Ok (Result { id })
    | "result", None, _, _, _ -> Error (`Json "result message must carry a non-null id")
    | "result", _, Some _, _, _ -> Error (`Json "result message must not carry capabilities")
    | "result", _, _, Some _, _ -> Error (`Json "result message must not carry message")
    | "result", _, _, _, Some _ -> Error (`Json "result message must not carry input_state")
    | "error", id, None, Some message, None -> Ok (Error { id; message })
    | "error", _, Some _, _, _ -> Error (`Json "error message must not carry capabilities")
    | "error", _, _, _, Some _ -> Error (`Json "error message must not carry input_state")
    | "error", _, None, None, None -> Error (`Json "error message missing message")
    | other, _, _, _, _ -> Error (`Unknown_type other)

let encode_client_message message =
  match Jsont_bytesrw.encode_string ~format:Jsont.Minify raw_client_jsont (raw_of_client_message message) with
  | Ok text -> text
  | Error msg -> invalid_arg ("Control.encode_client_message: " ^ msg)

let encode_server_message message =
  match Jsont_bytesrw.encode_string ~format:Jsont.Minify raw_server_jsont (raw_of_server_message message) with
  | Ok text -> text
  | Error msg -> invalid_arg ("Control.encode_server_message: " ^ msg)

let decode_client_message ~max_bytes text =
  if String.length text > max_bytes then E.fail `Oversize
  else
    match Jsont_bytesrw.decode_string raw_client_jsont text with
    | Error msg -> E.fail (`Json msg)
    | Ok raw -> ( match client_message_of_raw raw with Ok v -> Ok v | Error e -> E.fail e)

let decode_server_message ~max_bytes text =
  if String.length text > max_bytes then E.fail `Oversize
  else
    match Jsont_bytesrw.decode_string raw_server_jsont text with
    | Error msg -> E.fail (`Json msg)
    | Ok raw -> ( match server_message_of_raw raw with Ok v -> Ok v | Error e -> E.fail e)
