open Tessera_foundation
module Update = Tessera_model.Update

type error = [ `Identifier_exhausted | `Invalid_operation | `Snapshot_limit_exceeded ]
type state = { generation : Generation.t; state : State.t }
type cursor = { pending_wrap : bool; position : Types.coord; style : Tessera_model.Style.t }

type snapshot = {
  active : Types.screen;
  cells : Tessera_model.Collection.Snapshot_cells.t;
  cursor : cursor;
  cursor_visible : bool;
  generation : Generation.t;
  lineage_id : Lineage_id.t;
  size : Types.Size.t;
  title : string option;
}

type damage = { cursor_changed : bool; full : bool; rects : Tessera_model.Collection.Damage.t }
type applied = { damage : damage; patch : Patch.t; snapshot : snapshot; state : state }

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

let add_until ~upper value count = if count > upper - value then upper else value + count
let subtract_until ~lower value count = if count > value - lower then lower else value - count

let move size position = function
  | Update.Back count ->
      clip size
        (subtract_until ~lower:0 (UInt.to_int (Types.Column.to_uint position.Types.column)) (UInt.to_int count))
        (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Column column ->
      clip size (UInt.to_int (Types.Column.to_uint column)) (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Down count ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (add_until
           ~upper:(UInt.to_int (Types.Size.rows size) - 1)
           (UInt.to_int (Types.Row.to_uint position.Types.row))
           (UInt.to_int count))
  | Update.Forward count ->
      clip size
        (add_until
           ~upper:(UInt.to_int (Types.Size.columns size) - 1)
           (UInt.to_int (Types.Column.to_uint position.Types.column))
           (UInt.to_int count))
        (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Next_line count ->
      clip size 0
        (add_until
           ~upper:(UInt.to_int (Types.Size.rows size) - 1)
           (UInt.to_int (Types.Row.to_uint position.Types.row))
           (UInt.to_int count))
  | Update.Position position ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (UInt.to_int (Types.Row.to_uint position.Types.row))
  | Update.Previous_line count ->
      clip size 0 (subtract_until ~lower:0 (UInt.to_int (Types.Row.to_uint position.Types.row)) (UInt.to_int count))
  | Update.Row row ->
      clip size (UInt.to_int (Types.Column.to_uint position.Types.column)) (UInt.to_int (Types.Row.to_uint row))
  | Update.Up count ->
      clip size
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (subtract_until ~lower:0 (UInt.to_int (Types.Row.to_uint position.Types.row)) (UInt.to_int count))

let move_with_margins state buffer position = function
  | (Update.Down count | Update.Next_line count | Update.Previous_line count | Update.Up count) as movement
    when Tessera_model.Mode.origin (State.modes state) ->
      let margins = State.margins buffer in
      let top = UInt.to_int (Types.Row.to_uint margins.top) in
      let bottom = UInt.to_int (Types.Row.to_uint margins.bottom) in
      let row = UInt.to_int (Types.Row.to_uint position.Types.row) in
      let column = UInt.to_int (Types.Column.to_uint position.Types.column) in
      let row =
        match movement with
        | Update.Down _ | Update.Next_line _ -> add_until ~upper:bottom row (UInt.to_int count)
        | Update.Previous_line _ | Update.Up _ -> subtract_until ~lower:top row (UInt.to_int count)
        | _ -> assert false
      in
      let column =
        match movement with
        | Update.Next_line _ | Update.Previous_line _ -> 0
        | Update.Down _ | Update.Up _ -> column
        | _ -> assert false
      in
      clip (State.size state) column row
  | Update.Position position when Tessera_model.Mode.origin (State.modes state) ->
      let margins = State.margins buffer in
      clip (State.size state)
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (let top = UInt.to_int (Types.Row.to_uint margins.top) in
         let bottom = UInt.to_int (Types.Row.to_uint margins.bottom) in
         top + min (bottom - top) (UInt.to_int (Types.Row.to_uint position.Types.row)))
  | Update.Row row when Tessera_model.Mode.origin (State.modes state) ->
      let margins = State.margins buffer in
      clip (State.size state)
        (UInt.to_int (Types.Column.to_uint position.Types.column))
        (let top = UInt.to_int (Types.Row.to_uint margins.top) in
         let bottom = UInt.to_int (Types.Row.to_uint margins.bottom) in
         top + min (bottom - top) (UInt.to_int (Types.Row.to_uint row)))
  | movement -> move (State.size state) position movement

let valid_margins state (margins : Update.margins) =
  Types.Row.compare margins.top margins.bottom < 0
  && UInt.compare (Types.Row.to_uint margins.bottom) (Types.Size.rows (State.size state)) < 0

let size_equal left right =
  UInt.equal (Types.Size.columns left) (Types.Size.columns right)
  && UInt.equal (Types.Size.rows left) (Types.Size.rows right)

let snapshot_within_limit policy size =
  let columns = UInt.to_int (Types.Size.columns size) in
  let rows = UInt.to_int (Types.Size.rows size) in
  let maximum = UInt.to_int (Limits.max_snapshot_cells (Policy.limits policy)) in
  rows <= maximum / columns

let patch_cursor (cursor : State.cursor) : Patch.cursor =
  { pending_wrap = cursor.pending_wrap; position = cursor.position; style = cursor.style }

let damage_rect coordinate =
  match
    Types.rect ~top:coordinate.Types.row ~left:coordinate.Types.column ~bottom:coordinate.Types.row
      ~right:coordinate.Types.column
  with
  | Ok rect -> rect
  | Error _ -> assert false

let uint value = match UInt.of_int value with Ok value -> value | Error _ -> assert false

let full_damage_rect size =
  match
    Types.rect
      ~top:(Types.Row.of_uint (uint 0))
      ~left:(Types.Column.of_uint (uint 0))
      ~bottom:(Types.Row.of_uint (uint (UInt.to_int (Types.Size.rows size) - 1)))
      ~right:(Types.Column.of_uint (uint (UInt.to_int (Types.Size.columns size) - 1)))
  with
  | Ok rect -> rect
  | Error _ -> assert false

let buffer_changes ~before ~after ~screen ~include_all =
  Grid.fold_left
    (fun changes coordinate cell ->
      if include_all || not (Tessera_model.Cell.equal (Grid.get before coordinate) cell) then
        Tessera_model.Collection.Cell_block.make ~screen ~coord:coordinate ~cell :: changes
      else changes)
    [] after

let patch_from_states ~before ~after ~before_generation ~after_generation ~resize_applied =
  let before_size = State.size before and after_size = State.size after in
  let resized = resize_applied || not (size_equal before_size after_size) in
  let primary =
    buffer_changes
      ~before:(State.grid (State.primary before))
      ~after:(State.grid (State.primary after))
      ~screen:Types.Primary ~include_all:resized
  in
  let alternate =
    buffer_changes
      ~before:(State.grid (State.alternate before))
      ~after:(State.grid (State.alternate after))
      ~screen:Types.Alternate ~include_all:resized
  in
  let active = State.active after in
  let active_changes = match active with Types.Alternate -> alternate | Types.Primary -> primary in
  let damage =
    Tessera_model.Collection.Damage.of_list
      (List.map (fun block -> damage_rect (Tessera_model.Collection.Cell_block.coord block)) active_changes)
  in
  let before_cursor = State.cursor (State.active_buffer before) in
  let after_cursor = State.cursor (State.active_buffer after) in
  let presentation : Patch.presentation =
    {
      active = (if State.active before = active then Patch.Keep else Patch.Set active);
      cursor = (if before_cursor = after_cursor then Patch.Keep else Patch.Set (patch_cursor after_cursor));
      cursor_visible =
        (if
           Tessera_model.Mode.cursor_visible (State.modes before)
           = Tessera_model.Mode.cursor_visible (State.modes after)
         then Patch.Keep
         else Patch.Set (Tessera_model.Mode.cursor_visible (State.modes after)));
      title = (if State.title before = State.title after then Patch.Keep else Patch.Set (State.title after));
    }
  in
  Patch.make ~after_generation ~before_generation ~before_size
    ~cells:(Tessera_model.Collection.Cell_blocks.of_list (primary @ alternate))
    ~damage ~lineage_id:(State.lineage_id after) ~presentation
    ~size:(if resized then Patch.Set after_size else Patch.Keep)

let damage_from_states ~before ~after ~resize_applied patch =
  let active_changed = State.active before <> State.active after in
  let before_cursor = State.cursor (State.active_buffer before) in
  let after_cursor = State.cursor (State.active_buffer after) in
  let cursor_changed =
    active_changed || before_cursor <> after_cursor
    || Tessera_model.Mode.cursor_visible (State.modes before) <> Tessera_model.Mode.cursor_visible (State.modes after)
  in
  let full = resize_applied || active_changed || not (size_equal (State.size before) (State.size after)) in
  {
    cursor_changed;
    full;
    rects =
      (if full then Tessera_model.Collection.Damage.singleton (full_damage_rect (State.size after))
       else Patch.damage patch);
  }

let blank (cursor : State.cursor) = Tessera_model.Cell.blank ~line_id:Line_id.zero ~style:cursor.style

let blank_like cell =
  Tessera_model.Cell.blank ~line_id:(Tessera_model.Cell.line_id cell) ~style:(Tessera_model.Cell.style cell)

let repair_wide_pairs grid =
  let size = Grid.size grid in
  let columns = UInt.to_int (Types.Size.columns size) and rows = UInt.to_int (Types.Size.rows size) in
  let rec columns_in_row result row column =
    if column = columns then result
    else
      let coordinate = clip size column row in
      let cell = Grid.get result coordinate in
      match Tessera_model.Cell.contents cell with
      | Tessera_model.Cell.Glyph grapheme when Tessera_model.Unicode.width grapheme = Tessera_model.Unicode.Two ->
          let paired =
            column + 1 < columns
            &&
            match Tessera_model.Cell.contents (Grid.get result (clip size (column + 1) row)) with
            | Tessera_model.Cell.Wide_continuation -> true
            | Tessera_model.Cell.Empty | Tessera_model.Cell.Glyph _ -> false
          in
          if paired then columns_in_row result row (column + 2)
          else columns_in_row (Grid.set result coordinate (blank_like cell)) row (column + 1)
      | Tessera_model.Cell.Wide_continuation ->
          columns_in_row (Grid.set result coordinate (blank_like cell)) row (column + 1)
      | Tessera_model.Cell.Empty | Tessera_model.Cell.Glyph _ -> columns_in_row result row (column + 1)
  in
  let rec rows_in_grid result row =
    if row = rows then result else rows_in_grid (columns_in_row result row 0) (row + 1)
  in
  rows_in_grid grid 0

let repair_active_grid state =
  let buffer = State.active_buffer state in
  State.with_active_buffer state (State.with_grid buffer (repair_wide_pairs (State.grid buffer)))

let repair_all_grids state =
  State.map_buffers state ~f:(fun buffer -> State.with_grid buffer (repair_wide_pairs (State.grid buffer)))

let save_cursor state =
  let buffer = State.active_buffer state in
  let cursor = State.cursor buffer in
  State.with_active_buffer state
    (State.with_saved buffer
       (Some
          {
            State.origin = Tessera_model.Mode.origin (State.modes state);
            position = cursor.position;
            style = cursor.style;
          }))

let restore_cursor state =
  let buffer = State.active_buffer state in
  match State.saved buffer with
  | None -> state
  | Some saved ->
      let modes =
        match Tessera_model.Mode.private_mode_delta ~enabled:saved.origin 6 with
        | Some delta -> Tessera_model.Mode.apply_delta (State.modes state) delta
        | None -> assert false
      in
      let position =
        clip (State.size state)
          (UInt.to_int (Types.Column.to_uint saved.position.Types.column))
          (UInt.to_int (Types.Row.to_uint saved.position.Types.row))
      in
      State.with_modes
        (State.with_active_buffer state
           (State.with_cursor buffer { pending_wrap = false; position; style = saved.style }))
        modes

let scroll_up_between grid (cursor : State.cursor) ~top ~bottom =
  let size = Grid.size grid in
  let columns = UInt.to_int (Types.Size.columns size) in
  let rec columns_in_row result row column =
    if column = columns then result
    else
      let destination = clip size column row in
      let cell = if row < bottom then Grid.get grid (clip size column (row + 1)) else blank cursor in
      columns_in_row (Grid.set result destination cell) row (column + 1)
  in
  let rec rows_in_grid result row =
    if row > bottom then result else rows_in_grid (columns_in_row result row 0) (row + 1)
  in
  rows_in_grid grid top

let scroll_up grid (cursor : State.cursor) =
  scroll_up_between grid cursor ~top:0 ~bottom:(UInt.to_int (Types.Size.rows (Grid.size grid)) - 1)

let scroll_down grid (cursor : State.cursor) =
  let size = Grid.size grid in
  let columns = UInt.to_int (Types.Size.columns size) and rows = UInt.to_int (Types.Size.rows size) in
  let rec columns_in_row result row column =
    if column = columns then result
    else
      let destination = clip size column row in
      let cell = if row > 0 then Grid.get grid (clip size column (row - 1)) else blank cursor in
      columns_in_row (Grid.set result destination cell) row (column + 1)
  in
  let rec rows_in_grid result row =
    if row = rows then result else rows_in_grid (columns_in_row result row 0) (row + 1)
  in
  rows_in_grid grid 0

let repeat count f value =
  let rec loop remaining value = if remaining = 0 then value else loop (remaining - 1) (f value) in
  loop count value

let erase_columns grid cursor row first last =
  let size = Grid.size grid in
  let rec loop grid column =
    if column > last then grid else loop (Grid.set grid (clip size column row) (blank cursor)) (column + 1)
  in
  loop grid first

let erase_line grid (cursor : State.cursor) = function
  | `Clear_left ->
      erase_columns grid cursor
        (UInt.to_int (Types.Row.to_uint cursor.position.Types.row))
        0
        (UInt.to_int (Types.Column.to_uint cursor.position.Types.column))
  | `Clear_line ->
      erase_columns grid cursor
        (UInt.to_int (Types.Row.to_uint cursor.position.Types.row))
        0
        (UInt.to_int (Types.Size.columns (Grid.size grid)) - 1)
  | `Clear_right ->
      erase_columns grid cursor
        (UInt.to_int (Types.Row.to_uint cursor.position.Types.row))
        (UInt.to_int (Types.Column.to_uint cursor.position.Types.column))
        (UInt.to_int (Types.Size.columns (Grid.size grid)) - 1)

let erase_display grid (cursor : State.cursor) = function
  | `Clear_all ->
      let rows = UInt.to_int (Types.Size.rows (Grid.size grid)) in
      let rec loop grid row =
        if row = rows then grid
        else loop (erase_columns grid cursor row 0 (UInt.to_int (Types.Size.columns (Grid.size grid)) - 1)) (row + 1)
      in
      loop grid 0
  | (`Clear_above | `Clear_below) as direction ->
      let size = Grid.size grid in
      let rows = UInt.to_int (Types.Size.rows size) in
      let columns = UInt.to_int (Types.Size.columns size) in
      let cursor_row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
      let cursor_column = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
      let rec loop grid row =
        if row = rows then grid
        else
          let first, last =
            match direction with
            | `Clear_above when row < cursor_row -> (0, columns - 1)
            | `Clear_above when row = cursor_row -> (0, cursor_column)
            | `Clear_below when row = cursor_row -> (cursor_column, columns - 1)
            | `Clear_below when row > cursor_row -> (0, columns - 1)
            | _ -> (1, 0)
          in
          loop (erase_columns grid cursor row first last) (row + 1)
      in
      loop grid 0

let erase_chars grid (cursor : State.cursor) count =
  let first = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
  let last = min (UInt.to_int (Types.Size.columns (Grid.size grid)) - 1) (first + UInt.to_int count - 1) in
  erase_columns grid cursor (UInt.to_int (Types.Row.to_uint cursor.position.Types.row)) first last

let delete_chars grid (cursor : State.cursor) count =
  let size = Grid.size grid in
  let first = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
  let row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let columns = UInt.to_int (Types.Size.columns size) in
  let count = min (UInt.to_int count) (columns - first) in
  let rec loop result column =
    if column >= columns then result
    else
      let cell = if column + count < columns then Grid.get grid (clip size (column + count) row) else blank cursor in
      loop (Grid.set result (clip size column row) cell) (column + 1)
  in
  loop grid first

let insert_chars grid (cursor : State.cursor) count =
  let size = Grid.size grid in
  let first = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
  let row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let last = UInt.to_int (Types.Size.columns size) - 1 in
  let count = min (UInt.to_int count) (last - first + 1) in
  let rec loop result column =
    if column < first then result
    else
      let cell = if column - count >= first then Grid.get grid (clip size (column - count) row) else blank cursor in
      loop (Grid.set result (clip size column row) cell) (column - 1)
  in
  loop grid last

let delete_lines grid (cursor : State.cursor) count =
  let size = Grid.size grid in
  let columns = UInt.to_int (Types.Size.columns size) in
  let first = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let rows = UInt.to_int (Types.Size.rows size) in
  let count = min (UInt.to_int count) (rows - first) in
  let rec columns_in_row result row column =
    if column = columns then result
    else
      let cell = if row + count < rows then Grid.get grid (clip size column (row + count)) else blank cursor in
      columns_in_row (Grid.set result (clip size column row) cell) row (column + 1)
  in
  let rec rows_in_grid result row =
    if row = rows then result else rows_in_grid (columns_in_row result row 0) (row + 1)
  in
  rows_in_grid grid first

let insert_lines grid (cursor : State.cursor) count =
  let size = Grid.size grid in
  let columns = UInt.to_int (Types.Size.columns size) in
  let first = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let last = UInt.to_int (Types.Size.rows size) - 1 in
  let count = min (UInt.to_int count) (last - first + 1) in
  let rec columns_in_row result row column =
    if column = columns then result
    else
      let cell = if row - count >= first then Grid.get grid (clip size column (row - count)) else blank cursor in
      columns_in_row (Grid.set result (clip size column row) cell) row (column + 1)
  in
  let rec rows_in_grid result row =
    if row < first then result else rows_in_grid (columns_in_row result row 0) (row - 1)
  in
  rows_in_grid grid last

let line_feed state buffer (cursor : State.cursor) =
  let size = State.size state in
  let column = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
  let row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let maximum = UInt.to_int (Types.Size.rows size) - 1 in
  let margins = State.margins buffer in
  let top = UInt.to_int (Types.Row.to_uint margins.top) and bottom = UInt.to_int (Types.Row.to_uint margins.bottom) in
  if row < maximum && row <> bottom then
    State.with_active_buffer state
      (State.with_cursor buffer { cursor with pending_wrap = false; position = clip size column (row + 1) })
  else if row = bottom then
    let buffer = State.with_grid buffer (scroll_up_between (State.grid buffer) cursor ~top ~bottom) in
    State.with_active_buffer state
      (State.with_cursor buffer { cursor with pending_wrap = false; position = clip size column row })
  else
    let buffer = State.with_grid buffer (scroll_up (State.grid buffer) cursor) in
    State.with_active_buffer state
      (State.with_cursor buffer { cursor with pending_wrap = false; position = clip size column maximum })

let begin_print state buffer (cursor : State.cursor) width =
  let size = State.size state in
  let column = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
  let row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
  let columns = UInt.to_int (Types.Size.columns size) in
  if (cursor.pending_wrap || column + width > columns) && Tessera_model.Mode.auto_wrap (State.modes state) then
    let state = line_feed state buffer { cursor with position = clip size 0 row; pending_wrap = false } in
    let buffer = State.active_buffer state in
    (state, buffer, State.cursor buffer)
  else (state, buffer, { cursor with pending_wrap = false })

let print_one state grapheme =
  let buffer = State.active_buffer state in
  let cursor = State.cursor buffer in
  let size = State.size state in
  match Tessera_model.Unicode.width grapheme with
  | Tessera_model.Unicode.Zero -> state
  | (Tessera_model.Unicode.One | Tessera_model.Unicode.Two) as width ->
      let width =
        match width with Tessera_model.Unicode.One -> 1 | Tessera_model.Unicode.Two -> 2 | Zero -> assert false
      in
      let column = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
      if
        width = 2
        && column + width > UInt.to_int (Types.Size.columns size)
        && not (Tessera_model.Mode.auto_wrap (State.modes state))
      then state
      else
        let state, buffer, cursor = begin_print state buffer cursor width in
        let position = cursor.position in
        let grid =
          Grid.set
            (if Tessera_model.Mode.insert (State.modes state) then
               insert_chars (State.grid buffer) cursor
                 (match UInt.of_int width with Ok count -> count | Error _ -> assert false)
             else State.grid buffer)
            position
            (Tessera_model.Cell.glyph ~line_id:Line_id.zero ~style:cursor.style grapheme)
        in
        let grid =
          if width = 1 then grid
          else
            let row = UInt.to_int (Types.Row.to_uint position.Types.row) in
            let column = UInt.to_int (Types.Column.to_uint position.Types.column) in
            Grid.set grid
              (clip size (column + 1) row)
              (Tessera_model.Cell.wide_continuation ~line_id:Line_id.zero ~style:cursor.style)
        in
        let column = UInt.to_int (Types.Column.to_uint position.Types.column) in
        let row = UInt.to_int (Types.Row.to_uint position.Types.row) in
        let last = UInt.to_int (Types.Size.columns size) - 1 in
        let position = clip size (min last (column + width)) row in
        let buffer = State.with_grid buffer grid in
        State.with_active_buffer state
          (State.with_cursor buffer
             { cursor with pending_wrap = column + width >= UInt.to_int (Types.Size.columns size); position })

let apply_operation state = function
  | Update.Alternate_screen `Enter_1049 -> State.switch_screen (save_cursor state) Types.Alternate
  | Update.Alternate_screen `Leave_1049 -> restore_cursor (State.switch_screen state Types.Primary)
  | Update.Print sequence ->
      repair_active_grid (Tessera_model.Unicode.Grapheme_sequence.fold_left print_one state sequence)
  | Update.Carriage_return ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      let position = clip (State.size state) 0 (UInt.to_int (Types.Row.to_uint cursor.position.Types.row)) in
      State.with_active_buffer state (State.with_cursor buffer { cursor with position; pending_wrap = false })
  | Update.Line_feed ->
      let buffer = State.active_buffer state in
      line_feed state buffer (State.cursor buffer)
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
      let position = move_with_margins state buffer cursor.position movement in
      State.with_active_buffer state (State.with_cursor buffer { cursor with position; pending_wrap = false })
  | Update.Set_style delta ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      State.with_active_buffer state
        (State.with_cursor buffer { cursor with style = Tessera_model.Style.apply_delta cursor.style delta })
  | Update.Set_mode delta -> State.with_modes state (Tessera_model.Mode.apply_delta (State.modes state) delta)
  | Update.Set_margins margins ->
      if not (valid_margins state margins) then state
      else
        let buffer = State.active_buffer state in
        let cursor = State.cursor buffer in
        let cursor = { cursor with pending_wrap = false; position = clip (State.size state) 0 0 } in
        State.with_active_buffer state (State.with_cursor (State.with_margins buffer margins) cursor)
  | Update.Erase (Update.Display direction) ->
      let buffer = State.active_buffer state in
      repair_active_grid
        (State.with_active_buffer state
           (State.with_grid buffer (erase_display (State.grid buffer) (State.cursor buffer) direction)))
  | Update.Erase (Update.Line direction) ->
      let buffer = State.active_buffer state in
      repair_active_grid
        (State.with_active_buffer state
           (State.with_grid buffer (erase_line (State.grid buffer) (State.cursor buffer) direction)))
  | Update.Edit (Update.Delete_chars count) ->
      let buffer = State.active_buffer state in
      repair_active_grid
        (State.with_active_buffer state
           (State.with_grid buffer (delete_chars (State.grid buffer) (State.cursor buffer) count)))
  | Update.Edit (Update.Erase_chars count) ->
      let buffer = State.active_buffer state in
      repair_active_grid
        (State.with_active_buffer state
           (State.with_grid buffer (erase_chars (State.grid buffer) (State.cursor buffer) count)))
  | Update.Edit (Update.Insert_chars count) ->
      let buffer = State.active_buffer state in
      repair_active_grid
        (State.with_active_buffer state
           (State.with_grid buffer (insert_chars (State.grid buffer) (State.cursor buffer) count)))
  | Update.Edit (Update.Delete_lines count) ->
      let buffer = State.active_buffer state in
      State.with_active_buffer state
        (State.with_grid buffer (delete_lines (State.grid buffer) (State.cursor buffer) count))
  | Update.Edit (Update.Insert_lines count) ->
      let buffer = State.active_buffer state in
      State.with_active_buffer state
        (State.with_grid buffer (insert_lines (State.grid buffer) (State.cursor buffer) count))
  | Update.Set_tab ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      let tabs = Tessera_model.Collection.Tab_stops.add (State.tabs buffer) cursor.position.Types.column in
      State.with_active_buffer state (State.with_tabs buffer tabs)
  | Update.Horizontal_tab ->
      let buffer = State.active_buffer state in
      let cursor = State.cursor buffer in
      let column = UInt.to_int (Types.Column.to_uint cursor.position.Types.column) in
      let row = UInt.to_int (Types.Row.to_uint cursor.position.Types.row) in
      let default = ((column / 8) + 1) * 8 in
      let column =
        match Tessera_model.Collection.Tab_stops.next (State.tabs buffer) cursor.position.Types.column with
        | None -> default
        | Some stop -> min default (UInt.to_int (Types.Column.to_uint stop))
      in
      State.with_active_buffer state
        (State.with_cursor buffer { cursor with pending_wrap = false; position = clip (State.size state) column row })
  | Update.Save_cursor -> save_cursor state
  | Update.Restore_cursor -> restore_cursor state
  | Update.Set_title title -> State.with_title state (Some title)
  | Update.Scroll_down count ->
      let buffer = State.active_buffer state in
      State.with_active_buffer state
        (State.with_grid buffer
           (repeat (UInt.to_int count) (fun grid -> scroll_down grid (State.cursor buffer)) (State.grid buffer)))
  | Update.Scroll_up count ->
      let buffer = State.active_buffer state in
      State.with_active_buffer state
        (State.with_grid buffer
           (repeat (UInt.to_int count) (fun grid -> scroll_up grid (State.cursor buffer)) (State.grid buffer)))
  | Update.Reset -> State.initial ~lineage_id:(State.lineage_id state) ~size:(State.size state)
  | Update.Resize size -> repair_all_grids (State.resize state size)
  | Update.Switch_screen screen -> State.switch_screen state screen

let apply policy (state : state) batch =
  match Generation.succ state.generation with
  | Error _ -> E.fail `Identifier_exhausted
  | Ok generation ->
      let before_generation = state.generation in
      let before_state = state.state in
      let resize_applied =
        Tessera_model.Update.Batch.fold_left
          (fun applied -> function Update.Resize _ -> true | _ -> applied)
          false batch
      in
      let next_state = Tessera_model.Update.Batch.fold_left apply_operation before_state batch in
      if not (snapshot_within_limit policy (State.size next_state)) then E.fail `Snapshot_limit_exceeded
      else
        let state = { generation; state = next_state } in
        let patch =
          patch_from_states ~before:before_state ~after:next_state ~before_generation ~after_generation:generation
            ~resize_applied
        in
        let damage = damage_from_states ~before:before_state ~after:next_state ~resize_applied patch in
        let snapshot =
          let active_buffer = State.active_buffer next_state in
          let state_cursor = State.cursor active_buffer in
          {
            active = State.active next_state;
            cells =
              (match
                 Tessera_model.Collection.Snapshot_cells.of_row_major ~size:(State.size next_state)
                   (Grid.cells (State.grid active_buffer))
               with
              | Some cells -> cells
              | None -> assert false);
            cursor =
              { pending_wrap = state_cursor.pending_wrap; position = state_cursor.position; style = state_cursor.style };
            cursor_visible = Tessera_model.Mode.cursor_visible (State.modes next_state);
            generation;
            lineage_id = State.lineage_id next_state;
            size = State.size next_state;
            title = State.title next_state;
          }
        in
        Ok { damage; patch; snapshot; state }

let damage value = value.damage
let patch value = value.patch
let snapshot value = value.snapshot
let state value = value.state
let cells value = value.cells
let active value = value.active
let cursor value = value.cursor
let cursor_visible value = value.cursor_visible
let generation value = value.generation
let lineage_id value = value.lineage_id
let size value = value.size
let title value = value.title

let pp ppf (value : state) =
  Format.fprintf ppf "renderer-state(generation=%a; size=%a)" Generation.pp value.generation Types.Size.pp
    (State.size value.state)

let pp_snapshot ppf (value : snapshot) =
  let pp_title ppf = function
    | None -> Format.pp_print_string ppf "none"
    | Some value -> Format.fprintf ppf "some(%S)" value
  in
  Format.fprintf ppf
    "snapshot(active=%a; cursor=(%a; pending-wrap=%b; style=%a); cursor-visible=%b; lineage=%a; generation=%a; \
     size=%a; title=%a)"
    Types.pp_screen value.active Types.pp_coord value.cursor.position value.cursor.pending_wrap Tessera_model.Style.pp
    value.cursor.style value.cursor_visible Lineage_id.pp value.lineage_id Generation.pp value.generation Types.Size.pp
    value.size pp_title value.title

let pp_damage ppf value =
  Format.fprintf ppf "damage(cursor-changed=%b; full=%b; rects=%a)" value.cursor_changed value.full
    Tessera_model.Collection.Damage.pp value.rects

let pp_applied ppf (value : applied) =
  Format.fprintf ppf "{damage=%a; patch=%a; snapshot=%a}" pp_damage value.damage Patch.pp value.patch pp_snapshot
    value.snapshot
