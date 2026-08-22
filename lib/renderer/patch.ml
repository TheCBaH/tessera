open Tessera_foundation

type error = [ `Generation_mismatch | `Lineage_mismatch ]
type cursor = { pending_wrap : bool; position : Types.coord; style : Tessera_model.Style.t }
type 'a change = Keep | Set of 'a

type presentation = {
  active : Types.screen change;
  cursor : cursor change;
  cursor_visible : bool change;
  title : string option change;
}

type t = {
  after_generation : Generation.t;
  before_generation : Generation.t;
  before_size : Types.Size.t;
  cells : Tessera_model.Collection.Cell_blocks.t;
  damage : Tessera_model.Collection.Damage.t;
  lineage_id : Lineage_id.t;
  presentation : presentation;
  size : Types.Size.t change;
}

let pp_error ppf = function
  | `Generation_mismatch -> Format.pp_print_string ppf "generation mismatch"
  | `Lineage_mismatch -> Format.pp_print_string ppf "lineage mismatch"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let empty_presentation = { active = Keep; cursor = Keep; cursor_visible = Keep; title = Keep }

let empty ~lineage_id ~generation ~size =
  {
    after_generation = generation;
    before_generation = generation;
    before_size = size;
    cells = Tessera_model.Collection.Cell_blocks.empty;
    damage = Tessera_model.Collection.Damage.empty;
    lineage_id;
    presentation = empty_presentation;
    size = Keep;
  }

let make ~after_generation ~before_generation ~before_size ~cells ~damage ~lineage_id ~presentation ~size =
  { after_generation; before_generation; before_size; cells; damage; lineage_id; presentation; size }

let successor patch after_generation = { patch with after_generation }
let after_generation value = value.after_generation
let before_generation value = value.before_generation
let before_size value = value.before_size
let cells value = value.cells
let damage value = value.damage
let lineage_id value = value.lineage_id
let presentation value = value.presentation
let size value = value.size

let normalize value =
  {
    value with
    cells = Tessera_model.Collection.Cell_blocks.normalize value.cells;
    damage = Tessera_model.Collection.Damage.normalize value.damage;
  }

let compose_change earlier later = match later with Keep -> earlier | Set _ -> later

let compose_presentation earlier later =
  {
    active = compose_change earlier.active later.active;
    cursor = compose_change earlier.cursor later.cursor;
    cursor_visible = compose_change earlier.cursor_visible later.cursor_visible;
    title = compose_change earlier.title later.title;
  }

let compose left right =
  if not (Lineage_id.equal left.lineage_id right.lineage_id) then E.fail `Lineage_mismatch
  else if not (Generation.equal left.after_generation right.before_generation) then E.fail `Generation_mismatch
  else
    let cells, damage =
      match right.size with
      | Keep ->
          ( Tessera_model.Collection.Cell_blocks.append left.cells right.cells,
            Tessera_model.Collection.Damage.union left.damage right.damage )
      | Set _ -> (right.cells, right.damage)
    in
    Ok
      (normalize
         {
           after_generation = right.after_generation;
           before_generation = left.before_generation;
           before_size = left.before_size;
           cells;
           damage;
           lineage_id = left.lineage_id;
           presentation = compose_presentation left.presentation right.presentation;
           size = compose_change left.size right.size;
         })

let pp_change pp ppf = function
  | Keep -> Format.pp_print_string ppf "keep"
  | Set value -> Format.fprintf ppf "set(%a)" pp value

let pp_cursor ppf value =
  Format.fprintf ppf "{position=%a; pending-wrap=%b; style=%a}" Types.pp_coord value.position value.pending_wrap
    Tessera_model.Style.pp value.style

let pp_title ppf = function
  | None -> Format.pp_print_string ppf "none"
  | Some value -> Format.fprintf ppf "some(%S)" value

let pp_presentation ppf value =
  Format.fprintf ppf "{active=%a; cursor=%a; cursor-visible=%a; title=%a}" (pp_change Types.pp_screen) value.active
    (pp_change pp_cursor) value.cursor (pp_change Format.pp_print_bool) value.cursor_visible (pp_change pp_title)
    value.title

let pp ppf value =
  Format.fprintf ppf "{lineage=%a; before=%a; after=%a; before-size=%a; cells=%a; damage=%a; presentation=%a; size=%a}"
    Lineage_id.pp value.lineage_id Generation.pp value.before_generation Generation.pp value.after_generation
    Types.Size.pp value.before_size Tessera_model.Collection.Cell_blocks.pp value.cells
    Tessera_model.Collection.Damage.pp value.damage pp_presentation value.presentation (pp_change Types.Size.pp)
    value.size
