open Tessera_foundation

type cursor = { pending_wrap : bool; position : Types.coord; style : Tessera_model.Style.t }
type saved_cursor = { origin : bool; position : Types.coord; style : Tessera_model.Style.t }

type buffer = {
  cursor : cursor;
  grid : Grid.t;
  saved : saved_cursor option;
  tabs : Tessera_model.Collection.Tab_stops.t;
}

type t = { active : Types.screen; alternate : buffer; lineage_id : Lineage_id.t; primary : buffer; size : Types.Size.t }

let zero = match UInt.of_int 0 with Ok value -> value | Error _ -> assert false
let origin = Types.coord ~column:(Types.Column.of_uint zero) ~row:(Types.Row.of_uint zero)

let initial ~lineage_id ~size =
  let grid = Grid.with_blank ~size ~line_id:Line_id.zero ~style:Tessera_model.Style.default in
  let cursor = { pending_wrap = false; position = origin; style = Tessera_model.Style.default } in
  let buffer = { cursor; grid; saved = None; tabs = Tessera_model.Collection.Tab_stops.empty } in
  { active = Primary; alternate = buffer; lineage_id; primary = buffer; size }

let active value = value.active
let alternate value = value.alternate
let primary value = value.primary
let lineage_id value = value.lineage_id
let size value = value.size
let switch_screen value active = { value with active }
let active_buffer value = match value.active with Alternate -> value.alternate | Primary -> value.primary
let cursor value = value.cursor
let grid value = value.grid
let saved value = value.saved
let tabs value = value.tabs
let with_cursor value cursor = { value with cursor }
let with_grid value grid = { value with grid }

let with_active_buffer state buffer =
  match state.active with Alternate -> { state with alternate = buffer } | Primary -> { state with primary = buffer }
