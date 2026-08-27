module Foundation = Tessera_foundation
module Model = Tessera_model

let ( let* ) = Result.bind

let ( and* ) left right =
  let* left = left in
  let* right = right in
  Ok (left, right)

let pp_result pp = Fmt.result ~ok:pp ~error:Format.pp_print_string

(* Applies [pp] directly to a still-wrapped [Err.Error.t]; [pp] is expected to be an [E.Error.pp]/[pp_kind]
   accessor that already knows how to render the wrapper. *)
let with_error pp result = Result.map_error (Format.asprintf "%a" pp) result

(* Unwraps [Err.Error.kind] before applying [pp]; [pp] is expected to be a bare [pp_error] accessor for the
   domain's [error] type. *)
let error_message pp error = Format.asprintf "%a" pp (Err.Error.kind error)
let with_error_kind pp result = Result.map_error (error_message pp) result
let uint value = with_error_kind Foundation.UInt.pp_error (Foundation.UInt.of_int value)

let size columns rows =
  let* columns = uint columns and* rows = uint rows in
  with_error_kind Foundation.Types.pp_error (Foundation.Types.Size.make ~columns ~rows)

let coord column row =
  let* column = uint column and* row = uint row in
  Ok (Foundation.Types.coord ~column:(Foundation.Types.Column.of_uint column) ~row:(Foundation.Types.Row.of_uint row))

let rect left top right bottom =
  let* left = uint left and* top = uint top and* right = uint right and* bottom = uint bottom in
  with_error_kind Foundation.Types.pp_error
    (Foundation.Types.rect ~left:(Foundation.Types.Column.of_uint left) ~top:(Foundation.Types.Row.of_uint top)
       ~right:(Foundation.Types.Column.of_uint right) ~bottom:(Foundation.Types.Row.of_uint bottom))

let cell scalar =
  Model.Cell.glyph ~line_id:Foundation.Line_id.zero ~style:Model.Style.default
    (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar))

let policy ?(max_columns = 80) ?(max_control_bytes = 1024) ?(max_csi_params = 16) ?(max_diagnostics = 16)
    ?(max_rows = 24) ?(max_snapshot_cells = 1920) () =
  let* max_columns = uint max_columns
  and* max_control_bytes = uint max_control_bytes
  and* max_csi_params = uint max_csi_params
  and* max_diagnostics = uint max_diagnostics
  and* max_rows = uint max_rows
  and* max_slice_bytes = uint 4096
  and* max_snapshot_cells = uint max_snapshot_cells in
  let* limits =
    with_error_kind Foundation.Limits.pp_error
      (Foundation.Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows
         ~max_slice_bytes ~max_snapshot_cells)
  in
  Ok (Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)

let slice text =
  let bytes = Bytes.of_string text in
  let* off = uint 0 and* len = uint (Bytes.length bytes) in
  with_error_kind Foundation.Types.pp_error (Foundation.Types.slice bytes ~off ~len)

let batch_of_updates updates =
  List.fold_left
    (fun batch update -> Model.Update.Batch.append batch (Model.Update.Batch.singleton update))
    Model.Update.Batch.empty updates
