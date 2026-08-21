module Cell_block = struct
  type t = unit

  let pp ppf () = Format.pp_print_string ppf "cell-blocks-unavailable"
end

module Cell_blocks = struct
  type t = Cell_block.t list

  let empty = []
  let fold_left = List.fold_left
  let normalize value = value
  let pp ppf value = Format.fprintf ppf "cell-blocks(%d)" (List.length value)
end

module Damage = struct
  type t = Tessera_foundation.Types.rect list

  let empty = []
  let singleton value = [ value ]
  let union left right = left @ right
  let pp ppf value = Format.fprintf ppf "damage(%d)" (List.length value)
end

module Snapshot_cells = struct
  type t = { cells : Cell.t array; size : Tessera_foundation.Types.Size.t }

  let get _ _ = invalid_arg "Tessera.Collection.Snapshot_cells.get: unavailable before renderer stage"
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
  let pp ppf value = Format.fprintf ppf "tab-stops(%d)" (Set.cardinal value)
end
