open Tessera_test_support.Support

let%expect_test "public facade round trips controlled repaintable patches" =
  let controlled_round_trip ~description ~policy ~target ~before source =
    let* _, repaint =
      with_error Tessera.Repaint.E.Error.pp_kind
        (Tessera.Repaint.compile description policy target (Tessera.Renderer.patch source))
    in
    let* chunks = with_error Tessera.Encoder.E.Error.pp_kind (Tessera.Encoder.encode description policy repaint) in
    let* continuation, items =
      Tessera.Encoder.fold_chunks
        (fun result chunk ->
          let* continuation, items = result in
          let* decoded = with_error Tessera.Decoder.E.Error.pp_kind (Tessera.Decoder.feed policy continuation chunk) in
          Ok (decoded.continuation, Tessera.Effect.Item_sequence.append items decoded.items))
        (Ok (Tessera.Decoder.initial, Tessera.Effect.Item_sequence.empty))
        chunks
    in
    let* finished = with_error Tessera.Decoder.E.Error.pp_kind (Tessera.Decoder.finish policy continuation) in
    let items = Tessera.Effect.Item_sequence.append items finished.items in
    let* updates =
      Tessera.Effect.Item_sequence.fold_left
        (fun result item ->
          let* updates = result in
          match item with
          | Tessera.Effect.Update update ->
              Ok (Tessera.Update.Batch.append updates (Tessera.Update.Batch.singleton update))
          | Tessera.Effect.Observation _ -> Error "unexpected decoder observation")
        (Ok Tessera.Update.Batch.empty) items
    in
    let* output = with_error Tessera.Renderer.E.Error.pp_kind (Tessera.Renderer.apply policy before updates) in
    Ok
      ( Tessera.Patch.normalize (Tessera.Renderer.patch source) = Tessera.Patch.normalize (Tessera.Renderer.patch output),
        Tessera.Renderer.snapshot source = Tessera.Renderer.snapshot output )
  in
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage = uint 1 and* one = uint 1 in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let initial = Tessera.Renderer.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let target = Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* glyph =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy initial
           (Tessera.Update.Batch.singleton
              (Tessera.Update.Print
                 (Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))))))
    in
    let* glyph = controlled_round_trip ~description ~policy ~target ~before:initial glyph in
    let* seeded =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy initial
           (Tessera.Update.Batch.singleton
              (Tessera.Update.Print
                 (Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))))))
    in
    let* seeded_target, _ =
      with_error Tessera.Repaint.E.Error.pp_kind
        (Tessera.Repaint.compile description policy target (Tessera.Renderer.patch seeded))
    in
    let* zero = uint 0 in
    let position =
      Tessera.Types.coord ~column:(Tessera.Types.Column.of_uint zero) ~row:(Tessera.Types.Row.of_uint zero)
    in
    let* erased =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy (Tessera.Renderer.state seeded)
           (batch_of_updates
              [
                Tessera.Update.Move_cursor (Tessera.Update.Position position);
                Tessera.Update.Edit (Tessera.Update.Erase_chars one);
              ]))
    in
    let* erased =
      controlled_round_trip ~description ~policy ~target:seeded_target ~before:(Tessera.Renderer.state seeded) erased
    in
    let* wide_columns = uint 3 in
    let* wide_size = with_error_kind Tessera.Types.pp_error (Tessera.Types.Size.make ~columns:wide_columns ~rows:one) in
    let wide_initial =
      Tessera.Renderer.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size:wide_size
    in
    let wide_target =
      Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size:wide_size
    in
    let* wide =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy wide_initial
           (Tessera.Update.Batch.singleton
              (Tessera.Update.Print
                 (Tessera.Unicode.Grapheme_sequence.singleton
                    (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x4e00))))))
    in
    let* wide = controlled_round_trip ~description ~policy ~target:wide_target ~before:wide_initial wide in
    Ok (glyph, erased, wide)
  in
  let pp_round_trip ppf (glyph, erased, wide) =
    let pp_case name ppf (patch, projection) = Format.fprintf ppf "%s: patch=%b; projection=%b" name patch projection in
    Format.fprintf ppf "%a@.%a@.%a" (pp_case "glyph") glyph (pp_case "erase") erased (pp_case "wide") wide
  in
  Format.printf "%a@." (pp_result pp_round_trip) result;
  [%expect
    {|
    glyph: patch=true; projection=true
    erase: patch=true; projection=true
    wide: patch=true; projection=true |}]
