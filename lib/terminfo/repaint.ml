module Cell = Tessera_model.Cell
module Collection = Tessera_model.Collection
module Patch = Tessera_renderer.Patch
module Types = Tessera_foundation.Types
module UInt = Tessera_foundation.UInt
module Unicode = Tessera_model.Unicode
module Update = Tessera_model.Update

type error =
  [ `Generation_mismatch
  | `Incomplete_wide_pair
  | `Lineage_mismatch
  | `Unsupported_attachment
  | `Unsupported_observation
  | `Unsupported_presentation ]

type target = {
  active : Types.screen;
  cells : Collection.Cell_blocks.t;
  cursor : Patch.cursor;
  cursor_visible : bool;
  generation : Tessera_foundation.Generation.t;
  lineage_id : Tessera_foundation.Lineage_id.t;
  modes : Tessera_model.Mode.t;
  size : Types.Size.t;
  title : string option;
}

let pp_error ppf = function
  | `Generation_mismatch -> Format.pp_print_string ppf "generation mismatch"
  | `Incomplete_wide_pair -> Format.pp_print_string ppf "incomplete wide pair"
  | `Lineage_mismatch -> Format.pp_print_string ppf "lineage mismatch"
  | `Unsupported_attachment -> Format.pp_print_string ppf "unsupported attachment"
  | `Unsupported_observation -> Format.pp_print_string ppf "unsupported observation"
  | `Unsupported_presentation -> Format.pp_print_string ppf "unsupported presentation"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let ( let* ) = Result.bind
let zero = match UInt.of_int 0 with Ok value -> value | Error _ -> assert false

let initial ~lineage_id ~policy:_ ~size =
  {
    active = Types.Primary;
    cells = Collection.Cell_blocks.empty;
    cursor =
      {
        pending_wrap = false;
        position = Types.coord ~column:(Types.Column.of_uint zero) ~row:(Types.Row.of_uint zero);
        style = Tessera_model.Style.default;
      };
    cursor_visible = true;
    generation = Tessera_foundation.Generation.zero;
    lineage_id;
    modes = Tessera_model.Mode.default;
    size;
    title = None;
  }

let cell_count cells =
  Collection.Cell_blocks.fold_left
    (fun count block -> Collection.Cell_block.fold_left (fun count _ _ -> count + 1) count block)
    0 cells

let pp_target ppf { active; cells; cursor; cursor_visible; generation; lineage_id; modes; size; title } =
  Format.fprintf ppf
    "target(active=%a; cells=%d; cursor=%a; cursor-visible=%b; lineage=%a; generation=%a; modes=%a; size=%a; title=%a)"
    Types.pp_screen active (cell_count cells) Patch.pp_cursor cursor cursor_visible Tessera_foundation.Lineage_id.pp
    lineage_id Tessera_foundation.Generation.pp generation Tessera_model.Mode.pp modes Types.Size.pp size
    (fun ppf -> function
      | None -> Format.pp_print_string ppf "none" | Some value -> Format.fprintf ppf "some(%S)" value)
    title

let size_equal left right =
  UInt.equal (Types.Size.columns left) (Types.Size.columns right)
  && UInt.equal (Types.Size.rows left) (Types.Size.rows right)

let batch_of_operations operations =
  let rec loop batch = function
    | [] -> batch
    | operation :: rest -> loop (Update.Batch.append batch (Update.Batch.singleton operation)) rest
  in
  loop Update.Batch.empty operations

let cell_operations ~active blocks =
  let* one = E.map_error ~pos:__POS__ (fun _ -> `Unsupported_attachment) (UInt.of_int 1) in
  let cells =
    Collection.Cell_blocks.fold_left
      (fun cells block ->
        Collection.Cell_block.fold_left
          (fun cells coordinate cell ->
            if Collection.Cell_block.screen block = active then (coordinate, cell) :: cells else cells)
          cells block)
      [] blocks
  in
  let adjacent left right =
    Types.Row.compare left.Types.row right.Types.row = 0
    && UInt.to_int (Types.Column.to_uint right.Types.column) = UInt.to_int (Types.Column.to_uint left.Types.column) + 1
  in
  let rec loop operations = function
    | [] -> Ok (List.rev operations)
    | (coordinate, cell) :: rest -> (
        if Cell.style cell <> Tessera_model.Style.default then E.fail ~pos:__POS__ `Unsupported_presentation
        else
          match Cell.contents cell with
          | Cell.Empty ->
              loop
                (Update.Edit (Update.Erase_chars one) :: Update.Move_cursor (Update.Position coordinate) :: operations)
                rest
          | Cell.Glyph grapheme when Unicode.width grapheme = Unicode.Two -> (
              match rest with
              | (next, continuation) :: remaining
                when adjacent coordinate next
                     && Cell.contents continuation = Cell.Wide_continuation
                     && Cell.style continuation = Tessera_model.Style.default ->
                  loop
                    (Update.Print (Unicode.Grapheme_sequence.singleton grapheme)
                    :: Update.Move_cursor (Update.Position coordinate) :: operations)
                    remaining
              | _ -> E.fail ~pos:__POS__ `Incomplete_wide_pair)
          | Cell.Glyph grapheme ->
              loop
                (Update.Print (Unicode.Grapheme_sequence.singleton grapheme)
                :: Update.Move_cursor (Update.Position coordinate) :: operations)
                rest
          | Cell.Wide_continuation -> E.fail ~pos:__POS__ `Incomplete_wide_pair)
  in
  loop [] (List.rev cells)

let presentation_operations ~reset target (presentation : Patch.presentation) =
  let active_supported =
    match presentation.active with
    | Patch.Keep -> true
    | Patch.Set Types.Primary -> true
    | Patch.Set Types.Alternate -> false
  in
  let cursor_visible_supported =
    match presentation.cursor_visible with Patch.Keep -> true | Patch.Set true -> true | Patch.Set false -> false
  in
  match presentation.title with
  | Patch.Set _ -> E.fail ~pos:__POS__ `Unsupported_presentation
  | Patch.Keep when (not active_supported) || not cursor_visible_supported ->
      E.fail ~pos:__POS__ `Unsupported_presentation
  | Patch.Keep ->
      let* cursor =
        match presentation.cursor with
        | Patch.Keep -> Ok target.cursor
        | Patch.Set ({ pending_wrap = false; position = _; style } as cursor) when style = Tessera_model.Style.default
          ->
            Ok cursor
        | Patch.Set _ -> E.fail ~pos:__POS__ `Unsupported_presentation
      in
      let cursor_changed = match presentation.cursor with Patch.Keep -> false | Patch.Set _ -> true in
      if reset || cursor_changed then Ok [ Update.Move_cursor (Update.Position cursor.position) ] else Ok []

let apply_presentation target (presentation : Patch.presentation) =
  let cursor_visible =
    match presentation.cursor_visible with
    | Patch.Keep -> target.cursor_visible
    | Patch.Set cursor_visible -> cursor_visible
  in
  let modes =
    match Tessera_model.Mode.private_mode_delta ~enabled:cursor_visible 25 with
    | Some delta -> Tessera_model.Mode.apply_delta target.modes delta
    | None -> assert false
  in
  {
    target with
    active = (match presentation.active with Patch.Keep -> target.active | Patch.Set active -> active);
    cursor = (match presentation.cursor with Patch.Keep -> target.cursor | Patch.Set cursor -> cursor);
    cursor_visible;
    modes;
    title = (match presentation.title with Patch.Keep -> target.title | Patch.Set title -> title);
  }

let visible_cells active blocks =
  Collection.Cell_blocks.of_list
    (List.rev
       (Collection.Cell_blocks.fold_left
          (fun cells block -> if Collection.Cell_block.screen block = active then block :: cells else cells)
          [] blocks))

let apply_cells target patch =
  let cells = visible_cells target.active (Patch.cells patch) in
  let cells =
    match Patch.size patch with Patch.Keep -> Collection.Cell_blocks.append target.cells cells | Patch.Set _ -> cells
  in
  { target with cells }

let compile _description _policy target patch =
  if not (Tessera_foundation.Lineage_id.equal target.lineage_id (Patch.lineage_id patch)) then
    E.fail ~pos:__POS__ `Lineage_mismatch
  else if not (Tessera_foundation.Generation.equal target.generation (Patch.before_generation patch)) then
    E.fail ~pos:__POS__ `Generation_mismatch
  else if not (size_equal target.size (Patch.before_size patch)) then E.fail ~pos:__POS__ `Generation_mismatch
  else
    let reset = match Patch.size patch with Patch.Keep -> false | Patch.Set _ -> true in
    let* presentation = presentation_operations ~reset target (Patch.presentation patch) in
    let next = apply_presentation target (Patch.presentation patch) in
    let* cells = cell_operations ~active:next.active (Patch.cells patch) in
    let next = apply_cells next patch in
    let size = match Patch.size patch with Patch.Keep -> next.size | Patch.Set size -> size in
    let baseline = if reset then [ Update.Reset ] else [] in
    Ok
      ( { next with generation = Patch.after_generation patch; size },
        batch_of_operations (baseline @ cells @ presentation) )

let active target = target.active
let cells target = target.cells
let cursor target = target.cursor
let cursor_visible target = target.cursor_visible
let generation target = target.generation
let modes target = target.modes
let size target = target.size
let title target = target.title
