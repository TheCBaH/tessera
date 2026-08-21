type invalid_limit = { name : string; value : int }
type error = [ `Invalid_limit of invalid_limit ]

type t = {
  max_columns : UInt.t;
  max_control_bytes : UInt.t;
  max_csi_params : UInt.t;
  max_diagnostics : UInt.t;
  max_rows : UInt.t;
  max_slice_bytes : UInt.t;
  max_snapshot_cells : UInt.t;
}

let pp_error ppf (`Invalid_limit { name; value }) = Format.fprintf ppf "invalid limit %s=%d" name value

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows ~max_slice_bytes ~max_snapshot_cells
    =
  let zero = match UInt.of_int 0 with Ok value -> value | Error _ -> assert false in
  if UInt.equal max_columns zero then E.fail (`Invalid_limit { name = "max_columns"; value = 0 })
  else if UInt.equal max_rows zero then E.fail (`Invalid_limit { name = "max_rows"; value = 0 })
  else if UInt.equal max_snapshot_cells zero then E.fail (`Invalid_limit { name = "max_snapshot_cells"; value = 0 })
  else
    Ok
      { max_columns; max_control_bytes; max_csi_params; max_diagnostics; max_rows; max_slice_bytes; max_snapshot_cells }

let max_columns value = value.max_columns
let max_control_bytes value = value.max_control_bytes
let max_csi_params value = value.max_csi_params
let max_diagnostics value = value.max_diagnostics
let max_rows value = value.max_rows
let max_slice_bytes value = value.max_slice_bytes
let max_snapshot_cells value = value.max_snapshot_cells

let pp ppf value =
  Format.fprintf ppf
    "{max_columns=%a; max_control_bytes=%a; max_csi_params=%a; max_diagnostics=%a; max_rows=%a; max_slice_bytes=%a; \
     max_snapshot_cells=%a}"
    UInt.pp value.max_columns UInt.pp value.max_control_bytes UInt.pp value.max_csi_params UInt.pp value.max_diagnostics
    UInt.pp value.max_rows UInt.pp value.max_slice_bytes UInt.pp value.max_snapshot_cells
