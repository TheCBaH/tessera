open Tessera_foundation

(* A grid is sparse at the page level.  Pages are deliberately small enough
   that a local edit only copies a bounded amount of storage, while blank
   regions share [blank] and need no allocation at all. *)
let page_columns = 32
let page_rows = 8
let page_cells = page_columns * page_rows

module Page_key = struct
  type t = int * int

  let compare = Stdlib.compare
end

module Pages = Map.Make (Page_key)

type page = Tessera_model.Cell.t array
type t = { blank : Tessera_model.Cell.t; copied_pages : int; pages : page Pages.t; size : Types.Size.t }

let columns grid = UInt.to_int (Types.Size.columns grid.size)
let rows grid = UInt.to_int (Types.Size.rows grid.size)
let coordinates { Types.column; row } = (UInt.to_int (Types.Column.to_uint column), UInt.to_int (Types.Row.to_uint row))
let page_key column row = (column / page_columns, row / page_rows)
let page_index column row = (row mod page_rows * page_columns) + (column mod page_columns)
let page_at grid column row = Pages.find_opt (page_key column row) grid.pages

let with_blank ~size ~line_id ~style =
  { blank = Tessera_model.Cell.blank ~line_id ~style; copied_pages = 0; pages = Pages.empty; size }

let size grid = grid.size

let get grid coordinate =
  let column, row = coordinates coordinate in
  match page_at grid column row with None -> grid.blank | Some page -> page.(page_index column row)

let set grid coordinate cell =
  let column, row = coordinates coordinate in
  let index = page_index column row in
  match page_at grid column row with
  | Some page when page.(index) = cell -> grid
  | page ->
      let page = match page with Some page -> Array.copy page | None -> Array.make page_cells grid.blank in
      page.(index) <- cell;
      { grid with copied_pages = grid.copied_pages + 1; pages = Pages.add (page_key column row) page grid.pages }

let iter f grid =
  let uint value = match UInt.of_int value with Ok value -> value | Error _ -> assert false in
  let rec columns_in_row row column =
    if column = columns grid then ()
    else
      let column = Types.Column.of_uint (uint column) in
      let row = Types.Row.of_uint (uint row) in
      f (Types.coord ~column ~row) (get grid { Types.column; row });
      columns_in_row (UInt.to_int (Types.Row.to_uint row)) (UInt.to_int (Types.Column.to_uint column) + 1)
  in
  let rec rows_in_grid row =
    if row = rows grid then ()
    else (
      columns_in_row row 0;
      rows_in_grid (row + 1))
  in
  rows_in_grid 0

let fold_left f initial grid =
  let uint value = match UInt.of_int value with Ok value -> value | Error _ -> assert false in
  let rec columns_in_row result row column =
    if column = columns grid then result
    else
      let column = Types.Column.of_uint (uint column) in
      let row = Types.Row.of_uint (uint row) in
      let result = f result (Types.coord ~column ~row) (get grid { Types.column; row }) in
      columns_in_row result (UInt.to_int (Types.Row.to_uint row)) (UInt.to_int (Types.Column.to_uint column) + 1)
  in
  let rec rows_in_grid result row =
    if row = rows grid then result else rows_in_grid (columns_in_row result row 0) (row + 1)
  in
  rows_in_grid initial 0

let resize grid size =
  let columns = UInt.to_int (Types.Size.columns size) and rows = UInt.to_int (Types.Size.rows size) in
  let pages =
    Pages.filter
      (fun (page_column, page_row) _ -> page_column * page_columns < columns && page_row * page_rows < rows)
      grid.pages
  in
  { grid with pages; size }

let cells grid =
  Array.init
    (columns grid * rows grid)
    (fun index ->
      let column = index mod columns grid and row = index / columns grid in
      match page_at grid column row with None -> grid.blank | Some page -> page.(page_index column row))

let stats grid = (Pages.cardinal grid.pages, grid.copied_pages)
let blank grid = grid.blank
let pages grid = Pages.bindings grid.pages

let of_pages ~blank ~size pages =
  if List.for_all (fun (_, page) -> Array.length page = page_cells) pages then
    Some
      {
        blank;
        copied_pages = 0;
        pages = List.fold_left (fun acc (key, page) -> Pages.add key page acc) Pages.empty pages;
        size;
      }
  else None
