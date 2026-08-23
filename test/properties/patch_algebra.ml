module Foundation = Tessera_foundation
module Model = Tessera_model

let renderer_size = Generators.size_exn 5 4
let apply_batch state batch = Tessera.Renderer.apply Generators.default_policy state batch

(* A patch is a diff relative to its own before_generation baseline, not a canonical encoding of a
   transition: e.g. setting a title and later clearing it back within one `apply` call nets to
   `title = Keep` in a one-shot patch, while the same net effect split across two `apply` calls
   produces two real, non-cancelling diffs (`Set "x"` then `Set None`) that compose to `Set None`.
   Both are correct: applied to the same baseline they produce the same projection, but their raw
   representations legitimately differ. So this compares the resulting *projection* (the final
   snapshot, which is canonical) rather than the two patches' raw structure, and separately excludes
   the generation counters, which always differ by one extra step for a two-call split regardless of
   content (see [Renderer.apply] advances generation once per call, not once per update). *)
let snapshot_content_signature snapshot =
  let { Tessera.Renderer.pending_wrap; position; style } = Tessera.Renderer.cursor snapshot in
  Format.asprintf "active=%a; cells=%a; cursor=(%a,%b,%a); cursor_visible=%b; size=%a; title=%a"
    Foundation.Types.pp_screen (Tessera.Renderer.active snapshot) Model.Collection.Snapshot_cells.pp
    (Tessera.Renderer.cells snapshot) Foundation.Types.pp_coord position pending_wrap Model.Style.pp style
    (Tessera.Renderer.cursor_visible snapshot)
    Foundation.Types.Size.pp (Tessera.Renderer.size snapshot) (Fmt.option Format.pp_print_string)
    (Tessera.Renderer.title snapshot)

let split_arbitrary =
  QCheck.make
    QCheck.Gen.(
      Generators.updates_gen ~max_length:12 renderer_size >>= fun updates ->
      int_bound (List.length updates) >>= fun split -> return (updates, split))
    ~print:(fun (updates, split) ->
      Printf.sprintf "split=%d updates=[%s]" split
        (String.concat "; " (List.map (Format.asprintf "%a" Model.Update.pp) updates)))

(* Design claim "Session composition is faithful" restated at the Renderer/Patch layer: applying a
   batch in one step, or split into two sequential renderer applications and composed, must reach
   the same resulting screen projection, and the two patches must still be adjacent enough to
   compose (see the comment on [snapshot_content_signature] for why the patches themselves are not
   compared structurally). *)
let sequential_matches_compose =
  QCheck.Test.make ~count:300 ~name:"sequential renderer application matches patch composition" split_arbitrary
    (fun (updates, split) ->
      let first_updates = List.filteri (fun index _ -> index < split) updates in
      let second_updates = List.filteri (fun index _ -> index >= split) updates in
      let initial =
        Tessera.Renderer.initial ~lineage_id:(Generators.lineage_of_int 10) ~policy:Generators.default_policy
          ~size:renderer_size
      in
      match apply_batch initial (Generators.batch_of updates) with
      | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
      | Ok whole -> (
          match apply_batch initial (Generators.batch_of first_updates) with
          | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
          | Ok applied_first -> (
              match apply_batch (Tessera.Renderer.state applied_first) (Generators.batch_of second_updates) with
              | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
              | Ok applied_second -> (
                  match
                    Tessera.Patch.compose (Tessera.Renderer.patch applied_first) (Tessera.Renderer.patch applied_second)
                  with
                  | Error _ -> QCheck.Test.fail_report "adjacent patches failed to compose"
                  | Ok _composed ->
                      snapshot_content_signature (Tessera.Renderer.snapshot applied_second)
                      = snapshot_content_signature (Tessera.Renderer.snapshot whole)))))

let resize_arbitrary =
  QCheck.make
    QCheck.Gen.(
      Generators.updates_gen ~max_length:8 renderer_size >>= fun updates ->
      Generators.size_gen ~max_columns:6 ~max_rows:5 >>= fun resized -> return (updates, resized))
    ~print:(fun (updates, _) -> Printf.sprintf "updates=%d" (List.length updates))

(* Design claim "Resize ingress is explicit and ordered" / patch algebra: a right patch produced by
   a resize is a full-projection composition barrier, discarding the left patch's cells and damage
   even though the two patches are otherwise adjacent. *)
let resize_is_a_composition_barrier =
  QCheck.Test.make ~count:200 ~name:"resize composed onto a patch chain is a full-projection barrier" resize_arbitrary
    (fun (updates, resized_size) ->
      let initial =
        Tessera.Renderer.initial ~lineage_id:(Generators.lineage_of_int 11) ~policy:Generators.default_policy
          ~size:renderer_size
      in
      match apply_batch initial (Generators.batch_of updates) with
      | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
      | Ok written -> (
          match
            apply_batch (Tessera.Renderer.state written)
              (Model.Update.Batch.singleton (Model.Update.Resize resized_size))
          with
          | Error _ -> QCheck.Test.fail_report "renderer apply reported an error for generated input"
          | Ok resized -> (
              match Tessera.Patch.compose (Tessera.Renderer.patch written) (Tessera.Renderer.patch resized) with
              | Error _ -> QCheck.Test.fail_report "adjacent patches failed to compose"
              | Ok composed -> (
                  Format.asprintf "%a" Model.Collection.Cell_blocks.pp
                    (Tessera.Patch.cells (Tessera.Patch.normalize composed))
                  = Format.asprintf "%a" Model.Collection.Cell_blocks.pp
                      (Tessera.Patch.cells (Tessera.Patch.normalize (Tessera.Renderer.patch resized)))
                  &&
                  match Tessera.Patch.size composed with
                  | Tessera.Patch.Set reported -> Generators.size_equal reported resized_size
                  | Tessera.Patch.Keep -> false))))

let tests = [ sequential_matches_compose; resize_is_a_composition_barrier ]
