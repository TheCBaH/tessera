module Wire = Tessera_foundation.Wire

type t = bytes

type restored = {
  session : Tessera.session;
  description_identity : string option;
  observer_position : Tessera_proxy_observer.Record.sequence;
}

type error =
  [ `Duplicate_field of string
  | `Inner of Tessera.Checkpoint.error
  | `Malformed of string
  | `Missing_field of string
  | `Unknown_version of int
  | `Wire of Wire.error ]

let pp_error ppf = function
  | `Duplicate_field field -> Format.fprintf ppf "duplicate field: %s" field
  | `Inner error -> Format.fprintf ppf "inner(%a)" Tessera.Checkpoint.pp_error error
  | `Malformed field -> Format.fprintf ppf "malformed %s" field
  | `Missing_field field -> Format.fprintf ppf "missing field: %s" field
  | `Unknown_version version -> Format.fprintf ppf "unknown version %d" version
  | `Wire error -> Format.fprintf ppf "wire(%a)" Wire.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let current_version = 1
let max_description_identity_bytes = 1024
let session_tag = 1
let identity_tag = 2
let position_tag = 3
let ( let* ) = Result.bind

let wire_read read reader =
  match read reader with Error error -> Error (`Wire (Err.Error.kind error)) | Ok value -> Ok value

let encode_identity buffer = function
  | None -> Wire.write_bool buffer false
  | Some value ->
      Wire.write_bool buffer true;
      Wire.write_string buffer value

let decode_identity reader : (string option, error) result =
  let* present = wire_read Wire.read_bool reader in
  if not present then Ok None
  else
    let* value = wire_read Wire.read_string reader in
    if String.length value > max_description_identity_bytes then Error (`Malformed "description_identity")
    else Ok (Some value)

let encode_position buffer position = Wire.write_varint buffer (Tessera_proxy_observer.Record.sequence_to_int position)

let decode_position reader : (Tessera_proxy_observer.Record.sequence, error) result =
  let* raw = wire_read Wire.read_varint reader in
  match Tessera_proxy_observer.Record.sequence_of_int raw with
  | value -> Ok value
  | exception Invalid_argument _ -> Error (`Malformed "observer_position")

let encode_session buffer session =
  Buffer.add_bytes buffer (Tessera.Checkpoint.to_bytes (Tessera.Checkpoint.of_session session))

let of_session ~session ~description_identity ~observer_position : t =
  let buffer = Buffer.create 512 in
  Wire.write_u8 buffer current_version;
  let field tag encode value =
    let inner = Buffer.create 64 in
    encode inner value;
    Wire.write_u8 buffer tag;
    Wire.write_bytes buffer (Buffer.to_bytes inner)
  in
  field session_tag encode_session session;
  field identity_tag encode_identity description_identity;
  field position_tag encode_position observer_position;
  Buffer.to_bytes buffer

(* Mirrors lib/core/checkpoint.ml's two-pass approach: collect each field's raw bytes first (also where
   duplicate/unknown tags are rejected), then decode each field. Unlike the inner Tessera.Checkpoint, no field here
   needs another field's value to validate itself, so decode order after collection does not matter. *)
let split_fields reader =
  let rec loop ~session ~identity ~position =
    if Wire.at_end reader then Ok (session, identity, position)
    else
      let* tag = wire_read Wire.read_u8 reader in
      let* payload = wire_read Wire.read_bytes reader in
      if tag = session_tag then
        if Option.is_some session then Error (`Duplicate_field "session")
        else loop ~session:(Some payload) ~identity ~position
      else if tag = identity_tag then
        if Option.is_some identity then Error (`Duplicate_field "description_identity")
        else loop ~session ~identity:(Some payload) ~position
      else if tag = position_tag then
        if Option.is_some position then Error (`Duplicate_field "observer_position")
        else loop ~session ~identity ~position:(Some payload)
      else Error (`Malformed "field tag")
  in
  loop ~session:None ~identity:None ~position:None

let to_restored (value : t) : (restored, error) Err.t =
  let reader = Wire.reader value in
  match wire_read Wire.read_u8 reader with
  | Error error -> E.fail error
  | Ok version -> (
      if version <> current_version then E.fail (`Unknown_version version)
      else
        match split_fields reader with
        | Error error -> E.fail error
        | Ok (None, _, _) -> E.fail (`Missing_field "session")
        | Ok (_, None, _) -> E.fail (`Missing_field "description_identity")
        | Ok (_, _, None) -> E.fail (`Missing_field "observer_position")
        | Ok (Some session_bytes, Some identity_bytes, Some position_bytes) -> (
            match Tessera.Checkpoint.to_session (Tessera.Checkpoint.of_bytes session_bytes) with
            | Error error -> E.fail (`Inner (Err.Error.kind error))
            | Ok session -> (
                match decode_identity (Wire.reader identity_bytes) with
                | Error error -> E.fail error
                | Ok description_identity -> (
                    match decode_position (Wire.reader position_bytes) with
                    | Error error -> E.fail error
                    | Ok observer_position -> Ok { session; description_identity; observer_position }))))

let of_bytes bytes = bytes
let to_bytes value = value
let pp ppf value = Format.fprintf ppf "proxy_checkpoint(%d bytes)" (Bytes.length value)
