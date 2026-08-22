open Tessera_foundation

type cursor = { pending_wrap : bool; position : Types.coord; style : Tessera_model.Style.t }
type saved_cursor = { origin : bool; position : Types.coord; style : Tessera_model.Style.t }

type buffer = {
  cursor : cursor;
  grid : Grid.t;
  margins : Tessera_model.Update.margins;
  saved : saved_cursor option;
  tabs : Tessera_model.Collection.Tab_stops.t;
}

type t = {
  active : Types.screen;
  alternate : buffer;
  lineage_id : Lineage_id.t;
  modes : Tessera_model.Mode.t;
  primary : buffer;
  size : Types.Size.t;
  title : string option;
}

let zero = match UInt.of_int 0 with Ok value -> value | Error _ -> assert false
let origin = Types.coord ~column:(Types.Column.of_uint zero) ~row:(Types.Row.of_uint zero)

let default_margins size =
  let bottom =
    match UInt.of_int (UInt.to_int (Types.Size.rows size) - 1) with
    | Ok value -> Types.Row.of_uint value
    | Error _ -> assert false
  in
  { Tessera_model.Update.bottom; top = Types.Row.of_uint zero }

let initial ~lineage_id ~size =
  let grid = Grid.with_blank ~size ~line_id:Line_id.zero ~style:Tessera_model.Style.default in
  let cursor = { pending_wrap = false; position = origin; style = Tessera_model.Style.default } in
  let buffer =
    { cursor; grid; margins = default_margins size; saved = None; tabs = Tessera_model.Collection.Tab_stops.empty }
  in
  {
    active = Primary;
    alternate = buffer;
    lineage_id;
    modes = Tessera_model.Mode.default;
    primary = buffer;
    size;
    title = None;
  }

let active value = value.active
let alternate value = value.alternate
let primary value = value.primary
let lineage_id value = value.lineage_id
let modes value = value.modes
let size value = value.size
let title value = value.title
let switch_screen value active = { value with active }
let active_buffer value = match value.active with Alternate -> value.alternate | Primary -> value.primary
let cursor value = value.cursor
let grid value = value.grid
let margins value = value.margins
let saved value = value.saved
let tabs value = value.tabs
let with_cursor value cursor = { value with cursor }
let with_grid value grid = { value with grid }
let with_margins value margins = { value with margins }
let with_saved value saved = { value with saved }
let with_tabs value tabs = { value with tabs }
let with_modes value modes = { value with modes }
let with_size value size = { value with size }
let with_title value title = { value with title }
let map_buffers value ~f = { value with alternate = f value.alternate; primary = f value.primary }

let resize value size =
  let maximum_column = UInt.to_int (Types.Size.columns size) - 1
  and maximum_row = UInt.to_int (Types.Size.rows size) - 1 in
  let uint value = match UInt.of_int value with Ok value -> value | Error _ -> assert false in
  let clip { Types.column; row } =
    Types.coord
      ~column:(Types.Column.of_uint (uint (min maximum_column (UInt.to_int (Types.Column.to_uint column)))))
      ~row:(Types.Row.of_uint (uint (min maximum_row (UInt.to_int (Types.Row.to_uint row)))))
  in
  let resize_buffer buffer =
    let cursor = buffer.cursor in
    {
      buffer with
      cursor = { cursor with pending_wrap = false; position = clip cursor.position };
      grid = Grid.resize buffer.grid size;
      margins = default_margins size;
    }
  in
  { value with alternate = resize_buffer value.alternate; primary = resize_buffer value.primary; size }

let with_active_buffer state buffer =
  match state.active with Alternate -> { state with alternate = buffer } | Primary -> { state with primary = buffer }
