module Foundation = Tessera_foundation

let ( let* ) = Result.bind

type error =
  [ `Invalid_count of Foundation.UInt.error
  | `Invalid_value of Foundation.Types.error
  | `Session of Tessera.Session.error ]

let pp_error ppf = function
  | `Invalid_count error -> Format.fprintf ppf "invalid-count(%a)" Foundation.UInt.pp_error error
  | `Invalid_value error -> Format.fprintf ppf "invalid-value(%a)" Foundation.Types.pp_error error
  | `Session error -> Format.fprintf ppf "session(%a)" Tessera.Session.pp_error error

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

type t = { mutable session : Tessera.session }

let create ~lineage_id ~policy ~size = { session = Tessera.initial ~lineage_id ~policy ~size }

let ingest t input =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Session error) (Tessera.ingest t.session input) in
  t.session <- Tessera.session outcome;
  Ok outcome

let finish t =
  let* outcome = E.map_error ~pos:__POS__ (fun error -> `Session error) (Tessera.finish t.session) in
  t.session <- Tessera.session outcome;
  Ok outcome

let resize t ~columns ~rows =
  let* columns = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int columns) in
  let* rows = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int rows) in
  let* size =
    E.map_error ~pos:__POS__ (fun error -> `Invalid_value error) (Foundation.Types.Size.make ~columns ~rows)
  in
  ingest t (Tessera.Out_of_band (Tessera.Resize size))

let push t text =
  let bytes = Bytes.of_string text in
  let* off = E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int 0) in
  let* len =
    E.map_error ~pos:__POS__ (fun error -> `Invalid_count error) (Foundation.UInt.of_int (Bytes.length bytes))
  in
  let* chunk = E.map_error ~pos:__POS__ (fun error -> `Invalid_value error) (Foundation.Types.slice bytes ~off ~len) in
  ingest t (Tessera.Bytes chunk)
