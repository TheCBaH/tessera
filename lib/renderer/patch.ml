type error = [ `Generation_mismatch | `Lineage_mismatch ]

type t = {
  after_generation : Tessera_foundation.Generation.t;
  before_generation : Tessera_foundation.Generation.t;
  lineage_id : Tessera_foundation.Lineage_id.t;
}

let pp_error ppf = function
  | `Generation_mismatch -> Format.pp_print_string ppf "generation mismatch"
  | `Lineage_mismatch -> Format.pp_print_string ppf "lineage mismatch"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let empty ~lineage_id ~generation = { after_generation = generation; before_generation = generation; lineage_id }
let successor patch after_generation = { patch with after_generation }
let after_generation value = value.after_generation
let before_generation value = value.before_generation
let lineage_id value = value.lineage_id

let compose left right =
  if not (Tessera_foundation.Lineage_id.equal left.lineage_id right.lineage_id) then E.fail `Lineage_mismatch
  else if not (Tessera_foundation.Generation.equal left.after_generation right.before_generation) then
    E.fail `Generation_mismatch
  else
    Ok
      {
        after_generation = right.after_generation;
        before_generation = left.before_generation;
        lineage_id = left.lineage_id;
      }

let pp ppf value =
  Format.fprintf ppf "{lineage=%a; before=%a; after=%a}" Tessera_foundation.Lineage_id.pp value.lineage_id
    Tessera_foundation.Generation.pp value.before_generation Tessera_foundation.Generation.pp value.after_generation
