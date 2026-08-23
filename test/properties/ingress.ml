module Foundation = Tessera_foundation
module Model = Tessera_model

let rect_area region =
  let open Foundation.Types in
  let width =
    Foundation.UInt.to_int (Column.to_uint (rect_right region))
    - Foundation.UInt.to_int (Column.to_uint (rect_left region))
    + 1
  in
  let height =
    Foundation.UInt.to_int (Row.to_uint (rect_bottom region))
    - Foundation.UInt.to_int (Row.to_uint (rect_top region))
    + 1
  in
  width * height

let damage_area damage = Model.Collection.Damage.fold_left (fun total rect -> total + rect_area rect) 0 damage

let run_sequence ~lineage_id ~size inputs =
  let rec loop session acc = function
    | [] -> Ok (List.rev acc)
    | input :: rest -> (
        match Tessera.ingest session input with
        | Ok outcome -> loop (Tessera.session outcome) (outcome :: acc) rest
        | Error _ as error -> error)
  in
  loop (Tessera.initial ~lineage_id ~policy:Generators.default_policy ~size) [] inputs

let max_columns = 6
let max_rows = 5

let input_gen =
  QCheck.Gen.oneof_weighted
    [
      (3, QCheck.Gen.map (fun text -> Tessera.Bytes (Generators.slice_exn text)) Generators.random_terminal_bytes);
      ( 2,
        QCheck.Gen.map
          (fun size -> Tessera.Out_of_band (Tessera.Resize size))
          (Generators.size_gen ~max_columns ~max_rows) );
    ]

let sequence_gen =
  QCheck.Gen.(
    Generators.size_gen ~max_columns ~max_rows >>= fun size ->
    list_size (int_range 1 12) input_gen >>= fun inputs -> return (size, inputs))

let arbitrary =
  QCheck.make sequence_gen ~print:(fun (size, inputs) ->
      Printf.sprintf "size=%dx%d inputs=[%s]"
        (Foundation.UInt.to_int (Foundation.Types.Size.columns size))
        (Foundation.UInt.to_int (Foundation.Types.Size.rows size))
        (String.concat ";"
           (List.map
              (function
                | Tessera.Bytes slice ->
                    Printf.sprintf "bytes(%d)" (Foundation.UInt.to_int (Foundation.Types.slice_len slice))
                | Tessera.Out_of_band (Tessera.Resize size) ->
                    Printf.sprintf "resize(%dx%d)"
                      (Foundation.UInt.to_int (Foundation.Types.Size.columns size))
                      (Foundation.UInt.to_int (Foundation.Types.Size.rows size)))
              inputs)))

(* Design claim "Resize ingress is explicit and ordered": every accepted resize ingress -- whatever
   byte ingresses precede or follow it, and whether or not its size differs from the current
   geometry -- advances generation, emits exactly one ordered [Resize] observation, and reports full
   damage; a byte ingress never fabricates a resize observation. *)
let resize_ordering =
  QCheck.Test.make ~count:300 ~name:"resize ingress is explicit, ordered, and always a full refresh" arbitrary
    (fun (size, inputs) ->
      match run_sequence ~lineage_id:(Generators.lineage_of_int 1) ~size inputs with
      | Error _ -> QCheck.Test.fail_report "session ingest reported an error for generated input"
      | Ok outcomes ->
          List.for_all2
            (fun input outcome ->
              let items =
                List.rev
                  (Model.Effect.Item_sequence.fold_left
                     (fun acc item -> item :: acc)
                     [] (Tessera.outcome_items outcome))
              in
              let patch = Tessera.outcome_patch outcome in
              match input with
              | Tessera.Out_of_band (Tessera.Resize resized_size) ->
                  items = [ Model.Effect.Observation (Model.Effect.Resize resized_size) ]
                  && Foundation.Generation.compare (Tessera.Patch.after_generation patch)
                       (Tessera.Patch.before_generation patch)
                     > 0
                  && (match Tessera.Patch.size patch with
                    | Tessera.Patch.Set reported -> Generators.size_equal reported resized_size
                    | Tessera.Patch.Keep -> false)
                  && damage_area (Tessera.Patch.damage patch) = Generators.size_area resized_size
              | Tessera.Bytes _ ->
                  List.for_all (function Model.Effect.Observation (Model.Effect.Resize _) -> false | _ -> true) items)
            inputs outcomes)

(* Design claim "Resize ingress is explicit and ordered", same-geometry case: resizing to the
   renderer's current size is still an observable full-projection refresh, not a no-op. *)
let same_size_refresh_is_barrier =
  QCheck.Test.make ~count:200 ~name:"a same-size resize is a full refresh and a patch composition barrier"
    (QCheck.make
       QCheck.Gen.(
         Generators.size_gen ~max_columns ~max_rows >>= fun size ->
         list_size (int_range 0 3) Generators.random_terminal_bytes >>= fun texts -> return (size, texts)))
    (fun (size, texts) ->
      let byte_inputs = List.map (fun text -> Tessera.Bytes (Generators.slice_exn text)) texts in
      let inputs = byte_inputs @ [ Tessera.Out_of_band (Tessera.Resize size) ] in
      match run_sequence ~lineage_id:(Generators.lineage_of_int 2) ~size inputs with
      | Error _ -> QCheck.Test.fail_report "session ingest reported an error for generated input"
      | Ok outcomes -> (
          let resize_outcome = List.nth outcomes (List.length outcomes - 1) in
          let resize_patch = Tessera.outcome_patch resize_outcome in
          let full_refresh =
            (match Tessera.Patch.size resize_patch with
              | Tessera.Patch.Set reported -> Generators.size_equal reported size
              | Tessera.Patch.Keep -> false)
            && damage_area (Tessera.Patch.damage resize_patch) = Generators.size_area size
            && Foundation.Generation.compare
                 (Tessera.Patch.after_generation resize_patch)
                 (Tessera.Patch.before_generation resize_patch)
               > 0
          in
          match List.rev outcomes with
          | _ :: preceding :: _ -> (
              (* The resize patch composed onto the preceding patch must equal the resize patch alone:
                 same-geometry resize is a full-projection barrier, not merely a distinct event. *)
              match Tessera.Patch.compose (Tessera.outcome_patch preceding) resize_patch with
              | Ok composed ->
                  full_refresh
                  && Format.asprintf "%a" Model.Collection.Cell_blocks.pp
                       (Tessera.Patch.cells (Tessera.Patch.normalize composed))
                     = Format.asprintf "%a" Model.Collection.Cell_blocks.pp
                         (Tessera.Patch.cells (Tessera.Patch.normalize resize_patch))
              | Error _ -> QCheck.Test.fail_report "adjacent patches failed to compose")
          | _ -> full_refresh))

let tests = [ resize_ordering; same_size_refresh_is_barrier ]
