open Tessera_foundation

type error = [ `Malformed of string | `Unknown_kind of int | `Unknown_version of int | `Wire of Wire.error ]

let pp_error ppf = function
  | `Malformed field -> Format.fprintf ppf "malformed %s" field
  | `Unknown_kind kind -> Format.fprintf ppf "unknown frame kind %d" kind
  | `Unknown_version version -> Format.fprintf ppf "unknown protocol version %d" version
  | `Wire error -> Format.fprintf ppf "wire(%a)" Wire.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let current_version = 1
let ( let* ) = Result.bind

let wire_read read reader =
  match read reader with Error error -> Error (`Wire (Err.Error.kind error)) | Ok value -> Ok value

let encode_size buffer size =
  Wire.write_varint buffer (UInt.to_int (Types.Size.columns size));
  Wire.write_varint buffer (UInt.to_int (Types.Size.rows size))

let decode_size reader =
  let read_uint reader =
    let* raw = wire_read Wire.read_varint reader in
    if raw < 0 then Error (`Malformed "size")
    else match UInt.of_int raw with Error _ -> Error (`Malformed "size") | Ok value -> Ok value
  in
  let* columns = read_uint reader in
  let* rows = read_uint reader in
  match Types.Size.make ~columns ~rows with Error _ -> Error (`Malformed "size") | Ok size -> Ok size

let encode_coord buffer (coord : Types.coord) =
  Wire.write_varint buffer (UInt.to_int (Types.Column.to_uint coord.column));
  Wire.write_varint buffer (UInt.to_int (Types.Row.to_uint coord.row))

let decode_coord reader =
  let read_uint reader =
    let* raw = wire_read Wire.read_varint reader in
    if raw < 0 then Error (`Malformed "coord")
    else match UInt.of_int raw with Error _ -> Error (`Malformed "coord") | Ok value -> Ok value
  in
  let* column = read_uint reader in
  let* row = read_uint reader in
  Ok (Types.coord ~column:(Types.Column.of_uint column) ~row:(Types.Row.of_uint row))

let encode_screen buffer = function
  | Types.Primary -> Wire.write_u8 buffer 0
  | Types.Alternate -> Wire.write_u8 buffer 1

let decode_screen reader =
  let* tag = wire_read Wire.read_u8 reader in
  match tag with 0 -> Ok Types.Primary | 1 -> Ok Types.Alternate | _ -> Error (`Malformed "screen tag")

let encode_direction buffer = function
  | Types.Application_to_terminal -> Wire.write_u8 buffer 0
  | Types.Terminal_to_application -> Wire.write_u8 buffer 1

let decode_direction reader =
  let* tag = wire_read Wire.read_u8 reader in
  match tag with
  | 0 -> Ok Types.Application_to_terminal
  | 1 -> Ok Types.Terminal_to_application
  | _ -> Error (`Malformed "direction tag")

let encode_byte_offset buffer offset = Wire.write_varint64 buffer (UInt64.to_int64 (Byte_offset.to_uint64 offset))

let decode_byte_offset reader =
  let* raw = wire_read Wire.read_varint64 reader in
  match UInt64.of_int64 raw with
  | Error _ -> Error (`Malformed "byte offset")
  | Ok value -> Ok (Byte_offset.of_uint64 value)

module Pixels = struct
  type unit_ = Device_pixels | Css_pixels | Unspecified
  type t = { width : int; height : int; unit_ : unit_ }

  let pp_unit_ ppf = function
    | Device_pixels -> Format.pp_print_string ppf "device-pixels"
    | Css_pixels -> Format.pp_print_string ppf "css-pixels"
    | Unspecified -> Format.pp_print_string ppf "unspecified-unit"

  let pp ppf { width; height; unit_ } = Format.fprintf ppf "%dx%d(%a)" width height pp_unit_ unit_

  let of_record ({ width; height; unit } : Tessera_proxy_observer.Record.Pixels.t) =
    let unit_ =
      match unit with
      | Tessera_proxy_observer.Record.Pixels.Device_pixels -> Device_pixels
      | Tessera_proxy_observer.Record.Pixels.Css_pixels -> Css_pixels
      | Tessera_proxy_observer.Record.Pixels.Unspecified -> Unspecified
    in
    { width; height; unit_ }

  let encode buffer { width; height; unit_ } =
    Wire.write_varint buffer width;
    Wire.write_varint buffer height;
    Wire.write_u8 buffer (match unit_ with Device_pixels -> 0 | Css_pixels -> 1 | Unspecified -> 2)

  let decode reader =
    let* width = wire_read Wire.read_varint reader in
    let* height = wire_read Wire.read_varint reader in
    let* tag = wire_read Wire.read_u8 reader in
    match tag with
    | 0 -> Ok { width; height; unit_ = Device_pixels }
    | 1 -> Ok { width; height; unit_ = Css_pixels }
    | 2 -> Ok { width; height; unit_ = Unspecified }
    | _ -> Error (`Malformed "pixel unit tag")
end

let encode_pixels_opt buffer = function
  | None -> Wire.write_bool buffer false
  | Some pixels ->
      Wire.write_bool buffer true;
      Pixels.encode buffer pixels

let decode_pixels_opt reader =
  let* present = wire_read Wire.read_bool reader in
  if not present then Ok None
  else
    let* pixels = Pixels.decode reader in
    Ok (Some pixels)

let encode_diagnostic buffer (diagnostic : Tessera_model.Effect.diagnostic) =
  match diagnostic with
  | Control_string_too_long { kind; offset } ->
      Wire.write_u8 buffer 0;
      Wire.write_string buffer kind;
      encode_byte_offset buffer offset
  | Invalid_utf8 { offset } ->
      Wire.write_u8 buffer 1;
      encode_byte_offset buffer offset
  | Malformed_csi { offset; reason } ->
      Wire.write_u8 buffer 2;
      encode_byte_offset buffer offset;
      Wire.write_string buffer reason
  | Unsupported_sequence { family; offset } ->
      Wire.write_u8 buffer 3;
      Wire.write_string buffer family;
      encode_byte_offset buffer offset

let decode_diagnostic reader : (Tessera_model.Effect.diagnostic, error) result =
  let* tag = wire_read Wire.read_u8 reader in
  match tag with
  | 0 ->
      let* kind = wire_read Wire.read_string reader in
      let* offset = decode_byte_offset reader in
      Ok (Tessera_model.Effect.Control_string_too_long { kind; offset })
  | 1 ->
      let* offset = decode_byte_offset reader in
      Ok (Tessera_model.Effect.Invalid_utf8 { offset })
  | 2 ->
      let* offset = decode_byte_offset reader in
      let* reason = wire_read Wire.read_string reader in
      Ok (Tessera_model.Effect.Malformed_csi { offset; reason })
  | 3 ->
      let* family = wire_read Wire.read_string reader in
      let* offset = decode_byte_offset reader in
      Ok (Tessera_model.Effect.Unsupported_sequence { family; offset })
  | _ -> Error (`Malformed "diagnostic tag")

let encode_observation buffer (observation : Tessera_model.Effect.observation) =
  match observation with
  | Diagnostic diagnostic ->
      Wire.write_u8 buffer 0;
      encode_diagnostic buffer diagnostic
  | Resize size ->
      Wire.write_u8 buffer 1;
      encode_size buffer size

let decode_observation reader : (Tessera_model.Effect.observation, error) result =
  let* tag = wire_read Wire.read_u8 reader in
  match tag with
  | 0 ->
      let* diagnostic = decode_diagnostic reader in
      Ok (Tessera_model.Effect.Diagnostic diagnostic)
  | 1 ->
      let* size = decode_size reader in
      Ok (Tessera_model.Effect.Resize size)
  | _ -> Error (`Malformed "observation tag")

let encode_contents buffer (contents : Tessera_model.Cell.contents) =
  match contents with
  | Empty -> Wire.write_u8 buffer 0
  | Glyph grapheme ->
      Wire.write_u8 buffer 1;
      Wire.write_string buffer (Tessera_model.Unicode.utf8 grapheme)
  | Wide_continuation -> Wire.write_u8 buffer 2

(* [String.get_utf_8_uchar] is Stdlib since OCaml 4.14, matching this repository's baseline
   (dune-project requires [(ocaml (>= 4.14))]); it is used here, not the vendored Unicode submodules,
   because a grapheme's already-segmented UTF-8 text never needs re-running boundary rules -- only
   decoding the scalar sequence it already is. *)
let scalars_of_utf8 text =
  let length = String.length text in
  let rec loop offset acc =
    if offset >= length then Ok (List.rev acc)
    else
      let decode = String.get_utf_8_uchar text offset in
      if not (Uchar.utf_decode_is_valid decode) then Error (`Malformed "glyph utf-8")
      else loop (offset + Uchar.utf_decode_length decode) (Uchar.utf_decode_uchar decode :: acc)
  in
  loop 0 []

let encode_cells buffer cells =
  Wire.write_varint buffer (Array.length cells);
  Array.iter (encode_contents buffer) cells

let decode_cells reader =
  let* count = wire_read Wire.read_varint reader in
  if count < 0 then Error (`Malformed "cell count")
  else
    let rec build index acc =
      if index = count then Ok (Array.of_list (List.rev acc))
      else
        let* tag = wire_read Wire.read_u8 reader in
        match tag with
        | 0 -> build (index + 1) (Tessera_model.Cell.Empty :: acc)
        | 1 ->
            let* text = wire_read Wire.read_string reader in
            let* scalars = scalars_of_utf8 text in
            build (index + 1) (Tessera_model.Cell.Glyph (Tessera_model.Unicode.of_scalars scalars) :: acc)
        | 2 -> build (index + 1) (Tessera_model.Cell.Wide_continuation :: acc)
        | _ -> Error (`Malformed "cell tag")
    in
    build 0 []

module Authority = struct
  type t = { family : Policy.profile; max_columns : UInt.t; max_rows : UInt.t; reflow : [ `No_reflow ] }

  let make ~policy =
    let limits = Policy.limits policy in
    {
      family = Policy.profile policy;
      max_columns = Limits.max_columns limits;
      max_rows = Limits.max_rows limits;
      reflow = `No_reflow;
    }

  let pp ppf { family; max_columns; max_rows; reflow = `No_reflow } =
    Format.fprintf ppf "authority(%a; max=%a×%a; no-reflow)" Policy.pp_profile family UInt.pp max_columns UInt.pp
      max_rows

  let encode buffer { family; max_columns; max_rows; reflow = `No_reflow } =
    (match family with Policy.Xterm_256color_core -> Wire.write_u8 buffer 0);
    Wire.write_varint buffer (UInt.to_int max_columns);
    Wire.write_varint buffer (UInt.to_int max_rows);
    Wire.write_u8 buffer 0

  let decode reader =
    let* family_tag = wire_read Wire.read_u8 reader in
    let* family =
      match family_tag with 0 -> Ok Policy.Xterm_256color_core | _ -> Error (`Malformed "authority family")
    in
    let read_uint reader =
      let* raw = wire_read Wire.read_varint reader in
      if raw < 0 then Error (`Malformed "authority bound")
      else match UInt.of_int raw with Error _ -> Error (`Malformed "authority bound") | Ok value -> Ok value
    in
    let* max_columns = read_uint reader in
    let* max_rows = read_uint reader in
    let* reflow_tag = wire_read Wire.read_u8 reader in
    let* () = match reflow_tag with 0 -> Ok () | _ -> Error (`Malformed "authority reflow") in
    Ok { family; max_columns; max_rows; reflow = `No_reflow }
end

module Snapshot = struct
  type t = {
    active : Types.screen;
    cells : Tessera_model.Cell.contents array;
    cursor : Types.coord;
    cursor_visible : bool;
    position : int;
    size : Types.Size.t;
    title : string option;
  }

  let pp ppf { active; size; cursor; cursor_visible; title; position; cells } =
    Format.fprintf ppf "snapshot(%a; %a; cursor=%a visible=%b; title=%a; position=%d; %d cell(s))" Types.pp_screen
      active Types.Size.pp size Types.pp_coord cursor cursor_visible
      (fun ppf -> function None -> Format.pp_print_string ppf "none" | Some title -> Format.fprintf ppf "%S" title)
      title position (Array.length cells)

  let of_outcome ~position outcome =
    let snapshot = Tessera.outcome_snapshot outcome in
    let size = Tessera.Renderer.size snapshot in
    let cells_source = Tessera.Renderer.cells snapshot in
    let columns = UInt.to_int (Types.Size.columns size) and rows = UInt.to_int (Types.Size.rows size) in
    let cells =
      Array.init (columns * rows) (fun index ->
          let row =
            Types.Row.of_uint (match UInt.of_int (index / columns) with Ok v -> v | Error _ -> assert false)
          in
          let column =
            Types.Column.of_uint (match UInt.of_int (index mod columns) with Ok v -> v | Error _ -> assert false)
          in
          Tessera_model.Cell.contents
            (Tessera_model.Collection.Snapshot_cells.get cells_source (Types.coord ~column ~row)))
    in
    {
      active = Tessera.Renderer.active snapshot;
      cells;
      cursor = (Tessera.Renderer.cursor snapshot).position;
      cursor_visible = Tessera.Renderer.cursor_visible snapshot;
      position;
      size;
      title = Tessera.Renderer.title snapshot;
    }

  let encode buffer { active; size; cursor; cursor_visible; title; position; cells } =
    encode_screen buffer active;
    encode_size buffer size;
    encode_coord buffer cursor;
    Wire.write_bool buffer cursor_visible;
    (match title with
    | None -> Wire.write_bool buffer false
    | Some title ->
        Wire.write_bool buffer true;
        Wire.write_string buffer title);
    Wire.write_varint buffer position;
    encode_cells buffer cells

  let decode reader =
    let* active = decode_screen reader in
    let* size = decode_size reader in
    let* cursor = decode_coord reader in
    let* cursor_visible = wire_read Wire.read_bool reader in
    let* has_title = wire_read Wire.read_bool reader in
    let* title = if has_title then Result.map Option.some (wire_read Wire.read_string reader) else Ok None in
    let* position = wire_read Wire.read_varint reader in
    let* cells = decode_cells reader in
    let expected = UInt.to_int (Types.Size.columns size) * UInt.to_int (Types.Size.rows size) in
    if Array.length cells <> expected then Error (`Malformed "snapshot cell count")
    else Ok { active; cells; cursor; cursor_visible; position; size; title }
end

type traffic = { sequence : int; direction : Types.direction; bytes : Bytes.t }
type resize = { sequence : int; size : Types.Size.t; pixels : Pixels.t option }
type effect_observation = { sequence : int; item : Tessera_model.Effect.observation }

type t =
  | Authoritative_snapshot of Authority.t * Snapshot.t
  | Traffic of traffic
  | Resize of resize
  | Effect of effect_observation
  | Gap of { skipped : int; resume : int }

let of_record (record : Tessera_proxy_observer.Record.t) =
  match record with
  | Tessera_proxy_observer.Record.Traffic { sequence; direction; bytes } ->
      Traffic { sequence = Tessera_proxy_observer.Record.sequence_to_int sequence; direction; bytes }
  | Tessera_proxy_observer.Record.Resize { sequence; size; pixels } ->
      Resize
        {
          sequence = Tessera_proxy_observer.Record.sequence_to_int sequence;
          size;
          pixels = Option.map Pixels.of_record pixels;
        }
  | Tessera_proxy_observer.Record.Effect { sequence; item } ->
      Effect { sequence = Tessera_proxy_observer.Record.sequence_to_int sequence; item }

let pp ppf = function
  | Authoritative_snapshot (authority, snapshot) ->
      Format.fprintf ppf "snapshot(%a; %a)" Authority.pp authority Snapshot.pp snapshot
  | Traffic { sequence; direction; bytes } ->
      Format.fprintf ppf "traffic(#%d, %a, %d byte(s))" sequence Types.pp_direction direction (Bytes.length bytes)
  | Resize { sequence; size; pixels = None } -> Format.fprintf ppf "resize(#%d, %a)" sequence Types.Size.pp size
  | Resize { sequence; size; pixels = Some pixels } ->
      Format.fprintf ppf "resize(#%d, %a, %a)" sequence Types.Size.pp size Pixels.pp pixels
  | Effect { sequence; item } -> Format.fprintf ppf "effect(#%d, %a)" sequence Tessera_model.Effect.pp_observation item
  | Gap { skipped; resume } -> Format.fprintf ppf "gap(skipped=%d, resume=%d)" skipped resume

let encode_body buffer = function
  | Authoritative_snapshot (authority, snapshot) ->
      Wire.write_u8 buffer 1;
      Authority.encode buffer authority;
      Snapshot.encode buffer snapshot
  | Traffic { sequence; direction; bytes } ->
      Wire.write_u8 buffer 2;
      Wire.write_varint buffer sequence;
      encode_direction buffer direction;
      Wire.write_bytes buffer bytes
  | Resize { sequence; size; pixels } ->
      Wire.write_u8 buffer 3;
      Wire.write_varint buffer sequence;
      encode_size buffer size;
      encode_pixels_opt buffer pixels
  | Effect { sequence; item } ->
      Wire.write_u8 buffer 4;
      Wire.write_varint buffer sequence;
      encode_observation buffer item
  | Gap { skipped; resume } ->
      Wire.write_u8 buffer 5;
      Wire.write_varint buffer skipped;
      Wire.write_varint buffer resume

let encode buffer frame =
  let body = Buffer.create 64 in
  encode_body body frame;
  Wire.write_bytes buffer (Buffer.to_bytes body)

let write_preamble buffer = Wire.write_u8 buffer current_version

let decode_body payload : (t, error) result =
  let reader = Wire.reader payload in
  let* kind = wire_read Wire.read_u8 reader in
  match kind with
  | 1 ->
      let* authority = Authority.decode reader in
      let* snapshot = Snapshot.decode reader in
      Ok (Authoritative_snapshot (authority, snapshot))
  | 2 ->
      let* sequence = wire_read Wire.read_varint reader in
      let* direction = decode_direction reader in
      let* bytes = wire_read Wire.read_bytes reader in
      Ok (Traffic { sequence; direction; bytes })
  | 3 ->
      let* sequence = wire_read Wire.read_varint reader in
      let* size = decode_size reader in
      let* pixels = decode_pixels_opt reader in
      Ok (Resize { sequence; size; pixels })
  | 4 ->
      let* sequence = wire_read Wire.read_varint reader in
      let* item = decode_observation reader in
      Ok (Effect { sequence; item })
  | 5 ->
      let* skipped = wire_read Wire.read_varint reader in
      let* resume = wire_read Wire.read_varint reader in
      Ok (Gap { skipped; resume })
  | other -> Error (`Unknown_kind other)

type reader_state = Awaiting_preamble | Streaming
type reader = { state : reader_state; pending : bytes }

let reader () = { state = Awaiting_preamble; pending = Bytes.empty }

let rec drain state pending acc =
  match state with
  | Awaiting_preamble ->
      if Bytes.length pending < 1 then Ok ({ state; pending }, List.rev acc)
      else
        let version = Bytes.get_uint8 pending 0 in
        if version <> current_version then Error (`Unknown_version version)
        else drain Streaming (Bytes.sub pending 1 (Bytes.length pending - 1)) acc
  | Streaming -> (
      if Bytes.length pending = 0 then Ok ({ state; pending }, List.rev acc)
      else
        let wire_reader = Wire.reader pending in
        match Wire.read_bytes wire_reader with
        | Error error -> (
            match Err.Error.kind error with
            | `Truncated -> Ok ({ state; pending }, List.rev acc)
            | kind -> Error (`Wire kind))
        | Ok payload -> (
            let consumed = Bytes.length pending - Wire.remaining wire_reader in
            let leftover = Bytes.sub pending consumed (Bytes.length pending - consumed) in
            match decode_body payload with
            | Error error -> Error error
            | Ok frame -> drain Streaming leftover (frame :: acc)))

let feed reader chunk ~off ~len =
  let pending = Bytes.cat reader.pending (Bytes.sub chunk off len) in
  drain reader.state pending []
