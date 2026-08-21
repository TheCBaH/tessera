open Tessera_foundation

type t = { cells : Tessera_model.Cell.t array; size : Types.Size.t }

let columns grid = UInt.to_int (Types.Size.columns grid.size)
let rows grid = UInt.to_int (Types.Size.rows grid.size)

let index grid { Types.column; row } =
  (UInt.to_int (Types.Row.to_uint row) * columns grid) + UInt.to_int (Types.Column.to_uint column)

let with_blank ~size ~line_id ~style =
  let cells =
    Array.make
      (UInt.to_int (Types.Size.columns size) * UInt.to_int (Types.Size.rows size))
      (Tessera_model.Cell.blank ~line_id ~style)
  in
  { cells; size }

let size grid = grid.size
let get grid coordinate = grid.cells.(index grid coordinate)

let set grid coordinate cell =
  let cells = Array.copy grid.cells in
  cells.(index grid coordinate) <- cell;
  { grid with cells }

let iter f grid =
  for row = 0 to rows grid - 1 do
    for column = 0 to columns grid - 1 do
      let column = Types.Column.of_uint (match UInt.of_int column with Ok value -> value | Error _ -> assert false) in
      let row = Types.Row.of_uint (match UInt.of_int row with Ok value -> value | Error _ -> assert false) in
      f (Types.coord ~column ~row) (get grid { Types.column; row })
    done
  done

let resize grid size =
  let blank = grid.cells.(0) in
  let result =
    { cells = Array.make (UInt.to_int (Types.Size.columns size) * UInt.to_int (Types.Size.rows size)) blank; size }
  in
  let copy_rows = min (rows grid) (rows result) and copy_columns = min (columns grid) (columns result) in
  for row = 0 to copy_rows - 1 do
    Array.blit grid.cells (row * columns grid) result.cells (row * columns result) copy_columns
  done;
  result

let stats _ = (1, 1)
