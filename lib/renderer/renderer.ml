open Tessera_foundation
module Update = Tessera_model.Update

type error = [ `Identifier_exhausted | `Invalid_operation | `Snapshot_limit_exceeded ]
type state = { generation : Generation.t; state : State.t }
type snapshot = { active : Types.screen; generation : Generation.t; lineage_id : Lineage_id.t; size : Types.Size.t }
type applied = { patch : Patch.t; snapshot : snapshot; state : state }

let pp_error ppf = function
  | `Identifier_exhausted -> Format.pp_print_string ppf "identifier exhausted"
  | `Invalid_operation -> Format.pp_print_string ppf "invalid operation"
  | `Snapshot_limit_exceeded -> Format.pp_print_string ppf "snapshot limit exceeded"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let initial ~lineage_id ~policy:_ ~size = { generation = Generation.zero; state = State.initial ~lineage_id ~size }

let clip size column row =
  let max_column = UInt.to_int (Types.Size.columns size) - 1 and max_row = UInt.to_int (Types.Size.rows size) - 1 in
  let value value maximum = max 0 (min maximum value) in
  let uint value = match UInt.of_int value with Ok value -> value | Error _ -> assert false in
  Types.coord
    ~column:(Types.Column.of_uint (uint (value column max_column)))
    ~row:(Types.Row.of_uint (uint (value row max_row)))

let move size position = function
  | Update.Back count ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column) - UInt.to_int count)
        (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Column column ->
      clip size (UInt.to_int (Types.Column.to_uint column)) (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Down count ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (UInt.to_int (Types.Row.to_uint position.Types.row) + UInt.to_int count)
  | Update.Forward count ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column) + UInt.to_int count)
        (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Position position -> position
  | Update.Row row ->
      clip size (UInt.to_int (Types.Column.to_uint position.Types.column)) (UInt.to_int (Types.Row.to_uint row))
  | Update.Up count ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (UInt.to_int (Types.Row.to_uint position.Types.row) - UInt.to_int count)

let print_one state grapheme =
  let buffer = State.active_buffer state in
  let cursor = State.cursor buffer in
  let size = State.size state in
  let row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let position = if cursor.pending_wrap then clip size 0 (row + 1) else cursor.position in
  let cell = Tessera_model.Cell.glyph ~line_id:Line_id.zero ~style:cursor.style grapheme in
  let buffer = State.with_grid buffer (Grid.set (State.grid buffer) position cell) in
  let next =
    clip size
      (UInt.to_int (Types.Column.to_uint position.Types.column) + 1)
      (UInt.to_int (Types.Row.to_uint position.Types.row))
  in
  State.with_active_buffer state
    (State.with_cursor buffer
       {
         cursor with
         pending_wrap =
           UInt.to_int (Types.Column.to_uint position.Types.column) = UInt.to_int (Types.Size.columns size) - 1;
         position = next;
       })

let apply_operation state = function
  | Update.Print sequence -> Tessera_model.Unicode.Grapheme_sequence.fold_left print_one state sequence
  | Update.Carriage_return ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      let position = clip (State.size state) 0 (UInt.to_int (Types.Row.to_uint cursor.position.Types.row)) in
      State.with_active_buffer state (State.with_cursor buffer { cursor with position; pending_wrap = false })
  | Update.Line_feed ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      let position =
        clip (State.size state)
          (UInt.to_int (Types.Column.to_uint cursor.position.Types.column))
          (UInt.to_int (Types.Row.to_uint cursor.position.Types.row) + 1)
      in
      State.with_active_buffer state (State.with_cursor buffer { cursor with position; pending_wrap = false })
  | Update.Backspace ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      let position =
        clip (State.size state)
          (UInt.to_int (Types.Column.to_uint cursor.position.Types.column) - 1)
          (UInt.to_int (Types.Row.to_uint cursor.position.Types.row))
      in
      State.with_active_buffer state (State.with_cursor buffer { cursor with position; pending_wrap = false })
  | Update.Move_cursor movement ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      State.with_active_buffer state
        (State.with_cursor buffer
           { cursor with position = move (State.size state) cursor.position movement; pending_wrap = false })
  | Update.Set_style delta ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      State.with_active_buffer state
        (State.with_cursor buffer { cursor with style = Tessera_model.Style.apply_delta cursor.style delta })
  | Update.Switch_screen screen -> State.switch_screen state screen
  | _ -> state

let apply _policy (state : state) batch =
  match Generation.succ state.generation with
  | Error _ -> E.fail `Identifier_exhausted
  | Ok generation ->
      let before_generation = state.generation in
      let next_state = Tessera_model.Update.Batch.fold_left apply_operation state.state batch in
      let state = { generation; state = next_state } in
      let patch =
        Patch.successor (Patch.empty ~lineage_id:(State.lineage_id next_state) ~generation:before_generation) generation
      in
      let snapshot =
        {
          active = State.active next_state;
          generation;
          lineage_id = State.lineage_id next_state;
          size = State.size next_state;
        }
      in
      Ok { patch; snapshot; state }

let patch value = value.patch
let snapshot value = value.snapshot
let state value = value.state

let pp ppf (value : state) =
  Format.fprintf ppf "renderer-state(generation=%a; size=%a)" Generation.pp value.generation Types.Size.pp
    (State.size value.state)

let pp_snapshot ppf (value : snapshot) =
  Format.fprintf ppf "snapshot(active=%a; lineage=%a; generation=%a; size=%a)" Types.pp_screen value.active
    Lineage_id.pp value.lineage_id Generation.pp value.generation Types.Size.pp value.size

let pp_applied ppf (value : applied) =
  Format.fprintf ppf "{patch=%a; snapshot=%a}" Patch.pp value.patch pp_snapshot value.snapshot
