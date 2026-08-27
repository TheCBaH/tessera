module Cell_block = struct
  type t = { cells : Cell.t array; rect : Tessera_foundation.Types.rect; screen : Tessera_foundation.Types.screen }

  let uint value = match Tessera_foundation.UInt.of_int value with Ok value -> value | Error _ -> assert false

  let make_rect ~left ~right ~row =
    match
      Tessera_foundation.Types.rect
        ~top:(Tessera_foundation.Types.Row.of_uint (uint row))
        ~bottom:(Tessera_foundation.Types.Row.of_uint (uint row))
        ~left:(Tessera_foundation.Types.Column.of_uint (uint left))
        ~right:(Tessera_foundation.Types.Column.of_uint (uint right))
    with
    | Ok rect -> rect
    | Error _ -> assert false

  let make ~screen ~coord ~cell =
    let column =
      Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Column.to_uint coord.Tessera_foundation.Types.column)
    in
    let row =
      Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Row.to_uint coord.Tessera_foundation.Types.row)
    in
    { cells = [| cell |]; rect = make_rect ~left:column ~right:column ~row; screen }

  let make_row ~screen ~row ~left cells =
    let cells = Array.of_list cells in
    { cells; rect = make_rect ~left ~right:(left + Array.length cells - 1) ~row; screen }

  let make_rectangle ~screen ~top ~bottom ~left ~right cells =
    match
      Tessera_foundation.Types.rect
        ~top:(Tessera_foundation.Types.Row.of_uint (uint top))
        ~bottom:(Tessera_foundation.Types.Row.of_uint (uint bottom))
        ~left:(Tessera_foundation.Types.Column.of_uint (uint left))
        ~right:(Tessera_foundation.Types.Column.of_uint (uint right))
    with
    | Ok rect -> { cells = Array.of_list cells; rect; screen }
    | Error _ -> assert false

  let cell value = value.cells.(0)

  let coord value =
    Tessera_foundation.Types.coord
      ~column:(Tessera_foundation.Types.rect_left value.rect)
      ~row:(Tessera_foundation.Types.rect_top value.rect)

  let rect value = value.rect
  let screen value = value.screen
  let cells value = Array.to_list value.cells

  let fold_left f initial value =
    let columns =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_right value.rect))
      - Tessera_foundation.UInt.to_int
          (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_left value.rect))
      + 1
    in
    let left =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_left value.rect))
    in
    let top =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Row.to_uint (Tessera_foundation.Types.rect_top value.rect))
    in
    let rec loop result index =
      if index = Array.length value.cells then result
      else
        let column = Tessera_foundation.Types.Column.of_uint (uint (left + (index mod columns))) in
        let row = Tessera_foundation.Types.Row.of_uint (uint (top + (index / columns))) in
        loop (f result (Tessera_foundation.Types.coord ~column ~row) value.cells.(index)) (index + 1)
    in
    loop initial 0

  let pp ppf value =
    Format.fprintf ppf "cell-block(screen=%a; rect=%a; cells=[%a])" Tessera_foundation.Types.pp_screen value.screen
      Tessera_foundation.Types.pp_rect value.rect
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Cell.pp)
      (Array.to_list value.cells)
end

module Cell_blocks = struct
  type t = Cell_block.t list
  type cell = { cell : Cell.t; coord : Tessera_foundation.Types.coord; screen : Tessera_foundation.Types.screen }

  let compare_screen left right =
    match (left, right) with
    | Tessera_foundation.Types.Alternate, Tessera_foundation.Types.Primary -> -1
    | Tessera_foundation.Types.Primary, Tessera_foundation.Types.Alternate -> 1
    | _ -> 0

  let compare_coord left right =
    let row =
      Tessera_foundation.Types.Row.compare left.Tessera_foundation.Types.row right.Tessera_foundation.Types.row
    in
    if row <> 0 then row
    else
      Tessera_foundation.Types.Column.compare left.Tessera_foundation.Types.column right.Tessera_foundation.Types.column

  let compare left right =
    let screen = compare_screen left.screen right.screen in
    if screen <> 0 then screen else compare_coord left.coord right.coord

  let same_position left right = compare left right = 0

  let rec remove_position value = function
    | [] -> []
    | current :: rest ->
        if same_position value current then remove_position value rest else current :: remove_position value rest

  let cells_of_blocks blocks =
    List.rev
      (List.fold_left
         (fun result block ->
           Cell_block.fold_left
             (fun result coord cell -> { cell; coord; screen = Cell_block.screen block } :: result)
             result block)
         [] blocks)

  let canonical_cells blocks =
    List.sort compare
      (List.fold_left (fun result value -> value :: remove_position value result) [] (cells_of_blocks blocks))

  let column value =
    Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Column.to_uint value.coord.Tessera_foundation.Types.column)

  let row value =
    Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Row.to_uint value.coord.Tessera_foundation.Types.row)

  let rec take_run first previous reverse = function
    | current :: rest
      when current.screen = first.screen && row current = row first && column current = column previous + 1 ->
        take_run first current (current.cell :: reverse) rest
    | remaining -> (List.rev reverse, remaining)

  let compact cells =
    let rec row_runs result = function
      | [] -> List.rev result
      | first :: rest ->
          let run, remaining = take_run first first [ first.cell ] rest in
          let block = Cell_block.make_row ~screen:first.screen ~row:(row first) ~left:(column first) run in
          row_runs (block :: result) remaining
    in
    let top block =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Row.to_uint (Tessera_foundation.Types.rect_top (Cell_block.rect block)))
    in
    let bottom block =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Row.to_uint (Tessera_foundation.Types.rect_bottom (Cell_block.rect block)))
    in
    let left block =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_left (Cell_block.rect block)))
    in
    let right block =
      Tessera_foundation.UInt.to_int
        (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_right (Cell_block.rect block)))
    in
    let rec take_rectangle first previous reverse = function
      | current :: rest
        when Cell_block.screen current = Cell_block.screen first
             && left current = left first
             && right current = right first
             && top current = bottom previous + 1 ->
          take_rectangle first current (List.rev_append (Cell_block.cells current) reverse) rest
      | remaining -> (List.rev reverse, previous, remaining)
    in
    let rec rectangles result = function
      | [] -> List.rev result
      | first :: rest ->
          let cells, last, remaining = take_rectangle first first (List.rev (Cell_block.cells first)) rest in
          let block =
            Cell_block.make_rectangle ~screen:(Cell_block.screen first) ~top:(top first) ~bottom:(bottom last)
              ~left:(left first) ~right:(right first) cells
          in
          rectangles (block :: result) remaining
    in
    rectangles [] (row_runs [] cells)

  let empty = []
  let of_list blocks = compact (canonical_cells blocks)
  let append left right = of_list (left @ right)
  let fold_left = List.fold_left
  let normalize = of_list

  let pp ppf value =
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Cell_block.pp)
      value
end

module Damage = struct
  type t = Tessera_foundation.Types.rect list

  let compare left right =
    let top =
      Tessera_foundation.Types.Row.compare
        (Tessera_foundation.Types.rect_top left)
        (Tessera_foundation.Types.rect_top right)
    in
    if top <> 0 then top
    else
      let left_column =
        Tessera_foundation.Types.Column.compare
          (Tessera_foundation.Types.rect_left left)
          (Tessera_foundation.Types.rect_left right)
      in
      if left_column <> 0 then left_column
      else
        let bottom =
          Tessera_foundation.Types.Row.compare
            (Tessera_foundation.Types.rect_bottom left)
            (Tessera_foundation.Types.rect_bottom right)
        in
        if bottom <> 0 then bottom
        else
          Tessera_foundation.Types.Column.compare
            (Tessera_foundation.Types.rect_right left)
            (Tessera_foundation.Types.rect_right right)

  let lower_row value =
    Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Row.to_uint (Tessera_foundation.Types.rect_top value))

  let upper_row value =
    Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Row.to_uint (Tessera_foundation.Types.rect_bottom value))

  let lower_column value =
    Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_left value))

  let upper_column value =
    Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Column.to_uint (Tessera_foundation.Types.rect_right value))

  let overlap left right = left <= right
  let connected left right = left <= right || left = right + 1

  let mergeable left right =
    let rows_overlap = overlap (lower_row left) (upper_row right) && overlap (lower_row right) (upper_row left) in
    let columns_overlap =
      overlap (lower_column left) (upper_column right) && overlap (lower_column right) (upper_column left)
    in
    let rows_connected = connected (lower_row left) (upper_row right) && connected (lower_row right) (upper_row left) in
    let columns_connected =
      connected (lower_column left) (upper_column right) && connected (lower_column right) (upper_column left)
    in
    (rows_overlap && columns_connected) || (columns_overlap && rows_connected)

  let uint value = match Tessera_foundation.UInt.of_int value with Ok value -> value | Error _ -> assert false

  let merge left right =
    match
      Tessera_foundation.Types.rect
        ~top:(Tessera_foundation.Types.Row.of_uint (uint (min (lower_row left) (lower_row right))))
        ~bottom:(Tessera_foundation.Types.Row.of_uint (uint (max (upper_row left) (upper_row right))))
        ~left:(Tessera_foundation.Types.Column.of_uint (uint (min (lower_column left) (lower_column right))))
        ~right:(Tessera_foundation.Types.Column.of_uint (uint (max (upper_column left) (upper_column right))))
    with
    | Ok rect -> rect
    | Error _ -> assert false

  let rec merge_once = function
    | [] -> None
    | first :: rest -> (
        let rec find reverse = function
          | [] -> None
          | second :: remaining ->
              if mergeable first second then Some (List.rev_append reverse (merge first second :: remaining))
              else find (second :: reverse) remaining
        in
        match find [] rest with
        | Some result -> Some result
        | None -> Option.map (fun rest -> first :: rest) (merge_once rest))

  let rec normalize value =
    let value = List.sort compare value in
    match merge_once value with None -> value | Some value -> normalize value

  let empty = []
  let singleton value = [ value ]
  let of_list = normalize
  let union left right = normalize (left @ right)
  let fold_left = List.fold_left

  let pp ppf value =
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Tessera_foundation.Types.pp_rect)
      value
end

module Snapshot_cells = struct
  type t = { cells : Cell.t array; size : Tessera_foundation.Types.Size.t }

  let of_row_major ~size cells =
    let expected =
      Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Size.columns size)
      * Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Size.rows size)
    in
    if Array.length cells <> expected then None else Some { cells = Array.copy cells; size }

  let get value { Tessera_foundation.Types.column; row } =
    let columns = Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Size.columns value.size) in
    let column = Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Column.to_uint column) in
    let row = Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Row.to_uint row) in
    value.cells.((row * columns) + column)

  let size value = value.size
  let pp ppf value = Format.fprintf ppf "snapshot-cells(%d)" (Array.length value.cells)
end

module Tab_stops = struct
  module Set = Set.Make (struct
    type t = Tessera_foundation.Types.Column.t

    let compare = Tessera_foundation.Types.Column.compare
  end)

  type t = Set.t

  let empty = Set.empty
  let add value column = Set.add column value
  let remove value column = Set.remove column value
  let mem value column = Set.mem column value
  let next value column = Set.find_first_opt (fun next -> Tessera_foundation.Types.Column.compare next column > 0) value
  let fold_left f initial value = Set.fold (fun column result -> f result column) value initial
  let pp ppf value = Format.fprintf ppf "tab-stops(%d)" (Set.cardinal value)
end
