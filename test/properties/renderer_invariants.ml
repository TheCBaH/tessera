module Foundation = Tessera_foundation
module Model = Tessera_model

let renderer_size = Generators.size_exn 5 4

(* Design claim "Rendering invariants always hold": cursor stays in range; every Wide_continuation
   has a width-two lead immediately to its left and no width-two lead lacks its continuation; damage
   never escapes the current geometry; and the snapshot never exceeds the policy cell budget. This
   check only uses the public Tessera facade, matching what an external client can observe. *)
let check_invariants policy snapshot damage =
  let size = Tessera.Renderer.size snapshot in
  let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns size) in
  let rows = Foundation.UInt.to_int (Foundation.Types.Size.rows size) in
  let cells = Tessera.Renderer.cells snapshot in
  let cursor = Tessera.Renderer.cursor snapshot in
  let cursor_in_bounds =
    let { Tessera.Renderer.position; _ } = cursor in
    let column = Foundation.UInt.to_int (Foundation.Types.Column.to_uint position.Foundation.Types.column) in
    let row = Foundation.UInt.to_int (Foundation.Types.Row.to_uint position.Foundation.Types.row) in
    column >= 0 && column < columns && row >= 0 && row < rows
  in
  let get column row =
    Model.Collection.Snapshot_cells.get cells
      (Foundation.Types.coord ~column:(Generators.column_of_int column) ~row:(Generators.row_of_int row))
  in
  let is_wide_lead cell =
    match Model.Cell.contents cell with
    | Model.Cell.Glyph grapheme -> Model.Unicode.width grapheme = Model.Unicode.Two
    | _ -> false
  in
  let wide_pairing_ok =
    let ok = ref true in
    for row = 0 to rows - 1 do
      for column = 0 to columns - 1 do
        match Model.Cell.contents (get column row) with
        | Model.Cell.Wide_continuation -> if column = 0 || not (is_wide_lead (get (column - 1) row)) then ok := false
        | Model.Cell.Glyph grapheme when Model.Unicode.width grapheme = Model.Unicode.Two -> (
            if column + 1 >= columns then ok := false
            else
              match Model.Cell.contents (get (column + 1) row) with
              | Model.Cell.Wide_continuation -> ()
              | _ -> ok := false)
        | Model.Cell.Glyph _ | Model.Cell.Empty -> ()
      done
    done;
    !ok
  in
  let damage_in_bounds =
    Model.Collection.Damage.fold_left
      (fun ok rect ->
        let left = Foundation.UInt.to_int (Foundation.Types.Column.to_uint (Foundation.Types.rect_left rect)) in
        let right = Foundation.UInt.to_int (Foundation.Types.Column.to_uint (Foundation.Types.rect_right rect)) in
        let top = Foundation.UInt.to_int (Foundation.Types.Row.to_uint (Foundation.Types.rect_top rect)) in
        let bottom = Foundation.UInt.to_int (Foundation.Types.Row.to_uint (Foundation.Types.rect_bottom rect)) in
        ok && left >= 0 && top >= 0 && right < columns && bottom < rows && left <= right && top <= bottom)
      true damage
  in
  let snapshot_within_limit =
    columns * rows <= Foundation.UInt.to_int (Foundation.Limits.max_snapshot_cells (Foundation.Policy.limits policy))
  in
  cursor_in_bounds && wide_pairing_ok && damage_in_bounds && snapshot_within_limit

let batch_arbitrary =
  QCheck.make (Generators.updates_gen ~max_length:15 renderer_size) ~print:(fun updates ->
      Printf.sprintf "updates=%d" (List.length updates))

let invariants_after_random_batch =
  QCheck.Test.make ~count:400 ~name:"renderer invariants hold after every random update batch" batch_arbitrary
    (fun updates ->
      let initial =
        Tessera.Renderer.initial ~lineage_id:(Generators.lineage_of_int 20) ~policy:Generators.default_policy
          ~size:renderer_size
      in
      match Tessera.Renderer.apply Generators.default_policy initial (Generators.batch_of updates) with
      | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
      | Ok applied ->
          check_invariants Generators.default_policy (Tessera.Renderer.snapshot applied)
            (Tessera.Patch.damage (Tessera.Renderer.patch applied)))

let malformed_arbitrary =
  QCheck.make
    (QCheck.Gen.list_size (QCheck.Gen.int_range 1 5) Generators.random_terminal_bytes)
    ~print:(fun texts -> String.concat "|" (List.map (Printf.sprintf "%S") texts))

(* Same invariant checker, but driven through Session.ingest with arbitrary -- including malformed
   and unsupported -- byte fragments, matching "Invalid protocol data cannot alter state" /
   "Rendering invariants always hold ... after every malformed decoder input". *)
let invariants_after_malformed_ingress =
  QCheck.Test.make ~count:300 ~name:"renderer invariants hold after malformed decoder ingress" malformed_arbitrary
    (fun texts ->
      let session =
        Tessera.initial ~lineage_id:(Generators.lineage_of_int 21) ~policy:Generators.default_policy ~size:renderer_size
      in
      let rec loop session = function
        | [] -> true
        | text :: rest -> (
            match Tessera.ingest session (Tessera.Bytes (Generators.slice_exn text)) with
            | Error _ -> QCheck.Test.fail_report "session ingest reported an error for generated input"
            | Ok outcome ->
                check_invariants Generators.default_policy (Tessera.outcome_snapshot outcome)
                  (Tessera.Patch.damage (Tessera.outcome_patch outcome))
                && loop (Tessera.session outcome) rest)
      in
      loop session texts)

let tests = [ invariants_after_random_batch; invariants_after_malformed_ingress ]
