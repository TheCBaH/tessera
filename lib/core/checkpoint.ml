open Tessera_foundation

type t = bytes

type error =
  [ `Decoder of Tessera_decoder.Decoder.checkpoint_error
  | `Duplicate_field of string
  | `Limits of Limits.error
  | `Malformed of string
  | `Missing_field of string
  | `Renderer of Tessera_renderer.Renderer.checkpoint_error
  | `Unknown_version of int
  | `Wire of Wire.error ]

let pp_error ppf = function
  | `Decoder error -> Format.fprintf ppf "decoder(%a)" Tessera_decoder.Decoder.pp_checkpoint_error error
  | `Duplicate_field field -> Format.fprintf ppf "duplicate field: %s" field
  | `Limits error -> Format.fprintf ppf "limits(%a)" Limits.pp_error error
  | `Malformed field -> Format.fprintf ppf "malformed %s" field
  | `Missing_field field -> Format.fprintf ppf "missing field: %s" field
  | `Renderer error -> Format.fprintf ppf "renderer(%a)" Tessera_renderer.Renderer.pp_checkpoint_error error
  | `Unknown_version version -> Format.fprintf ppf "unknown version %d" version
  | `Wire error -> Format.fprintf ppf "wire(%a)" Wire.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let current_version = 1
let policy_tag = 1
let decoder_tag = 2
let renderer_tag = 3
let ( let* ) = Result.bind

let wire_read read reader =
  match read reader with Error error -> Error (`Wire (Err.Error.kind error)) | Ok value -> Ok value

let encode_policy buffer (policy : Policy.t) =
  let limits = Policy.limits policy in
  Wire.write_varint buffer (UInt.to_int (Limits.max_columns limits));
  Wire.write_varint buffer (UInt.to_int (Limits.max_control_bytes limits));
  Wire.write_varint buffer (UInt.to_int (Limits.max_csi_params limits));
  Wire.write_varint buffer (UInt.to_int (Limits.max_diagnostics limits));
  Wire.write_varint buffer (UInt.to_int (Limits.max_rows limits));
  Wire.write_varint buffer (UInt.to_int (Limits.max_slice_bytes limits));
  Wire.write_varint buffer (UInt.to_int (Limits.max_snapshot_cells limits));
  match Policy.profile policy with Policy.Xterm_256color_core -> Wire.write_u8 buffer 0

let decode_policy reader : (Policy.t, error) result =
  let read_uint reader =
    let* raw = wire_read Wire.read_varint reader in
    if raw < 0 then Error (`Malformed "policy limit")
    else match UInt.of_int raw with Error _ -> Error (`Malformed "policy limit") | Ok value -> Ok value
  in
  let* max_columns = read_uint reader in
  let* max_control_bytes = read_uint reader in
  let* max_csi_params = read_uint reader in
  let* max_diagnostics = read_uint reader in
  let* max_rows = read_uint reader in
  let* max_slice_bytes = read_uint reader in
  let* max_snapshot_cells = read_uint reader in
  let* profile_tag = wire_read Wire.read_u8 reader in
  let* profile =
    match profile_tag with 0 -> Ok Policy.Xterm_256color_core | _ -> Error (`Malformed "policy profile tag")
  in
  match
    Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows ~max_slice_bytes
      ~max_snapshot_cells
  with
  | Error error -> Error (`Limits (Err.Error.kind error))
  | Ok limits -> Ok (Policy.make ~limits ~profile)

let of_session (session : Session.t) : t =
  let buffer = Buffer.create 512 in
  Wire.write_u8 buffer current_version;
  let field tag encode value =
    let inner = Buffer.create 128 in
    encode inner value;
    Wire.write_u8 buffer tag;
    Wire.write_bytes buffer (Buffer.to_bytes inner)
  in
  field policy_tag encode_policy (Session.policy session);
  field decoder_tag Tessera_decoder.Decoder.encode_continuation (Session.decoder session);
  field renderer_tag Tessera_renderer.Renderer.encode (Session.renderer session);
  Buffer.to_bytes buffer

(* Fields may arrive in any order on the wire, but decoding the decoder/renderer payloads needs the policy's limits
   already in hand: collect each field's raw bytes first (also where duplicate/unknown tags are rejected), then
   decode policy before the two payloads that are validated against it. *)
let split_fields reader =
  let rec loop ~policy ~decoder ~renderer =
    if Wire.at_end reader then Ok (policy, decoder, renderer)
    else
      let* tag = wire_read Wire.read_u8 reader in
      let* payload = wire_read Wire.read_bytes reader in
      if tag = policy_tag then
        if Option.is_some policy then Error (`Duplicate_field "policy")
        else loop ~policy:(Some payload) ~decoder ~renderer
      else if tag = decoder_tag then
        if Option.is_some decoder then Error (`Duplicate_field "decoder")
        else loop ~policy ~decoder:(Some payload) ~renderer
      else if tag = renderer_tag then
        if Option.is_some renderer then Error (`Duplicate_field "renderer")
        else loop ~policy ~decoder ~renderer:(Some payload)
      else Error (`Malformed "field tag")
  in
  loop ~policy:None ~decoder:None ~renderer:None

let to_session (value : t) : (Session.t, error) Err.t =
  let reader = Wire.reader value in
  match wire_read Wire.read_u8 reader with
  | Error error -> E.fail error
  | Ok version -> (
      if version <> current_version then E.fail (`Unknown_version version)
      else
        match split_fields reader with
        | Error error -> E.fail error
        | Ok (None, _, _) -> E.fail (`Missing_field "policy")
        | Ok (_, None, _) -> E.fail (`Missing_field "decoder")
        | Ok (_, _, None) -> E.fail (`Missing_field "renderer")
        | Ok (Some policy_bytes, Some decoder_bytes, Some renderer_bytes) -> (
            match decode_policy (Wire.reader policy_bytes) with
            | Error error -> E.fail error
            | Ok policy -> (
                match Tessera_decoder.Decoder.decode_continuation (Wire.reader decoder_bytes) ~policy with
                | Error error -> E.fail (`Decoder (Err.Error.kind error))
                | Ok decoder -> (
                    match Tessera_renderer.Renderer.decode (Wire.reader renderer_bytes) ~policy with
                    | Error error -> E.fail (`Renderer (Err.Error.kind error))
                    | Ok renderer -> Ok (Session.make ~decoder ~policy ~renderer)))))

let of_bytes bytes = bytes
let to_bytes value = value
let pp ppf value = Format.fprintf ppf "checkpoint(%d bytes)" (Bytes.length value)
