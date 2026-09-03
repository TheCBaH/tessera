type target = Html | Canvas
type capabilities = { observe : bool; input : bool; resize : bool }
type client_message = Hello of { id : string; target : target } | Resync of { id : string } | Close of { id : string }

type server_message =
  | Ready of { id : string; capabilities : capabilities }
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
let version = 1
let pp_target ppf = function Html -> Format.pp_print_string ppf "html" | Canvas -> Format.pp_print_string ppf "canvas"

let pp_capabilities ppf { observe; input; resize } =
  Format.fprintf ppf "capabilities(observe=%b, input=%b, resize=%b)" observe input resize

let pp_client_message ppf = function
  | Hello { id; target } -> Format.fprintf ppf "hello(id=%S, target=%a)" id pp_target target
  | Resync { id } -> Format.fprintf ppf "resync(id=%S)" id
  | Close { id } -> Format.fprintf ppf "close(id=%S)" id

let pp_server_message ppf = function
  | Ready { id; capabilities } -> Format.fprintf ppf "ready(id=%S, %a)" id pp_capabilities capabilities
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

(* Raw client envelope: every field any client message can carry, decoded structurally by Jsont; the
   schema/version/type/field-combination checks below are plain OCaml so an unknown [schema]/[version]/[type] is a
   distinct typed error rather than folded into the generic [`Json] decode-failure case Jsont itself would report for
   a missing/mistyped field. *)
type raw_client = { c_schema : string; c_version : int; c_type : string; c_id : string; c_target : target option }

let raw_client_jsont =
  Jsont.Object.map (fun c_schema c_version c_type c_id c_target -> { c_schema; c_version; c_type; c_id; c_target })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun v -> v.c_schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun v -> v.c_version)
  |> Jsont.Object.mem "type" Jsont.string ~enc:(fun v -> v.c_type)
  |> Jsont.Object.mem "id" Jsont.string ~enc:(fun v -> v.c_id)
  |> Jsont.Object.opt_mem "target" target_jsont ~enc:(fun v -> v.c_target)
  |> Jsont.Object.finish

type raw_server = {
  s_schema : string;
  s_version : int;
  s_type : string;
  s_id : string option;
  s_capabilities : capabilities option;
  s_message : string option;
}

let raw_server_jsont =
  Jsont.Object.map (fun s_schema s_version s_type s_id s_capabilities s_message ->
      { s_schema; s_version; s_type; s_id; s_capabilities; s_message })
  |> Jsont.Object.mem "schema" Jsont.string ~enc:(fun v -> v.s_schema)
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun v -> v.s_version)
  |> Jsont.Object.mem "type" Jsont.string ~enc:(fun v -> v.s_type)
  |> Jsont.Object.mem "id" (Jsont.option Jsont.string) ~enc:(fun v -> v.s_id)
  |> Jsont.Object.opt_mem "capabilities" capabilities_jsont ~enc:(fun v -> v.s_capabilities)
  |> Jsont.Object.opt_mem "message" Jsont.string ~enc:(fun v -> v.s_message)
  |> Jsont.Object.finish

let raw_of_client_message = function
  | Hello { id; target } ->
      { c_schema = schema; c_version = version; c_type = "hello"; c_id = id; c_target = Some target }
  | Resync { id } -> { c_schema = schema; c_version = version; c_type = "resync"; c_id = id; c_target = None }
  | Close { id } -> { c_schema = schema; c_version = version; c_type = "close"; c_id = id; c_target = None }

let client_message_of_raw (raw : raw_client) : (client_message, error) result =
  if raw.c_schema <> schema then Error (`Unknown_schema raw.c_schema)
  else if raw.c_version <> version then Error (`Unknown_version raw.c_version)
  else
    match (raw.c_type, raw.c_target) with
    | "hello", Some target -> Ok (Hello { id = raw.c_id; target })
    | "hello", None -> Error (`Json "hello message missing target")
    | "resync", None -> Ok (Resync { id = raw.c_id })
    | "close", None -> Ok (Close { id = raw.c_id })
    | ("resync" | "close"), Some _ -> Error (`Json (raw.c_type ^ " message must not carry target"))
    | other, _ -> Error (`Unknown_type other)

let raw_of_server_message = function
  | Ready { id; capabilities } ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "ready";
        s_id = Some id;
        s_capabilities = Some capabilities;
        s_message = None;
      }
  | Result { id } ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "result";
        s_id = Some id;
        s_capabilities = None;
        s_message = None;
      }
  | Error { id; message } ->
      {
        s_schema = schema;
        s_version = version;
        s_type = "error";
        s_id = id;
        s_capabilities = None;
        s_message = Some message;
      }

let server_message_of_raw (raw : raw_server) : (server_message, error) result =
  if raw.s_schema <> schema then Error (`Unknown_schema raw.s_schema)
  else if raw.s_version <> version then Error (`Unknown_version raw.s_version)
  else
    match (raw.s_type, raw.s_id, raw.s_capabilities, raw.s_message) with
    | "ready", Some id, Some capabilities, None -> Ok (Ready { id; capabilities })
    | "ready", None, _, _ -> Error (`Json "ready message must carry a non-null id")
    | "ready", Some _, None, _ -> Error (`Json "ready message missing capabilities")
    | "result", Some id, None, None -> Ok (Result { id })
    | "result", None, _, _ -> Error (`Json "result message must carry a non-null id")
    | "result", _, Some _, _ -> Error (`Json "result message must not carry capabilities")
    | "error", id, None, Some message -> Ok (Error { id; message })
    | "error", _, Some _, _ -> Error (`Json "error message must not carry capabilities")
    | "error", _, None, None -> Error (`Json "error message missing message")
    | other, _, _, _ -> Error (`Unknown_type other)

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
