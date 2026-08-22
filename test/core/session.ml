module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let%expect_test "public session composes decoder and renderer" =
  let result =
    let* policy = policy ()
    and* size = size 2 1
    and* lineage_id = uint 2
    and* slice = slice "A\rB"
    and* coordinate = coord 0 0 in
    let session = Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    Result.map
      (fun outcome ->
        let cells = Tessera.Renderer.cells (Tessera.outcome_snapshot outcome) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
      (with_error_kind Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes slice)))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0041>) |}]

let%expect_test "session resize ingress is ordered, observable, and does not consume bytes" =
  let result =
    let* policy = policy ()
    and* size = size 2 1
    and* lineage_id = uint 7
    and* slice = slice "A"
    and* coordinate = coord 0 0 in
    let initial = Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* pending = with_error_kind Tessera.Session.pp_error (Tessera.ingest initial (Tessera.Bytes slice)) in
    let* resized =
      with_error_kind Tessera.Session.pp_error
        (Tessera.ingest (Tessera.session pending) (Tessera.Out_of_band (Tessera.Resize size)))
    in
    let* finished = with_error_kind Tessera.Session.pp_error (Tessera.finish (Tessera.session resized)) in
    let cell =
      Tessera.Renderer.cells (Tessera.outcome_snapshot finished) |> fun cells ->
      Model.Collection.Snapshot_cells.get cells coordinate |> Model.Cell.contents
    in
    Ok ((Tessera.outcome_items resized, Tessera.outcome_patch resized), cell)
  in
  Format.printf "%a@."
    (pp_result (Fmt.pair (Fmt.pair Model.Effect.Item_sequence.pp Renderer.Patch.pp) Model.Cell.pp_contents))
    result;
  [%expect
    {|
    [observation(resize(2×1))]
    {lineage=7; before=1; after=2; before-size=2×1; cells=[cell-block(screen=alternate; rect={top=0; left=0; bottom=0; right=1}; cells=[{contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}]); cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=1}; cells=[{contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=1}]; presentation={active=keep; cursor=keep; cursor-visible=keep; title=keep}; size=set(2×1)}
    glyph(<U+0041>) |}]

let%expect_test "retained sessions preserve earlier snapshots" =
  let result =
    let* policy = policy ()
    and* size = size 2 1
    and* lineage_id = uint 5
    and* first_slice = slice "A"
    and* second_slice = slice "B"
    and* coordinate = coord 1 0 in
    let initial = Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* pending_first =
      with_error_kind Tessera.Session.pp_error (Tessera.ingest initial (Tessera.Bytes first_slice))
    in
    let* first = with_error_kind Tessera.Session.pp_error (Tessera.finish (Tessera.session pending_first)) in
    let* pending_second =
      with_error_kind Tessera.Session.pp_error (Tessera.ingest (Tessera.session first) (Tessera.Bytes second_slice))
    in
    let* second = with_error_kind Tessera.Session.pp_error (Tessera.finish (Tessera.session pending_second)) in
    let contents outcome =
      let cells = Tessera.Renderer.cells (Tessera.outcome_snapshot outcome) in
      Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate)
    in
    Ok (contents first, contents second)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Model.Cell.pp_contents Model.Cell.pp_contents)) result;
  [%expect {|
    empty
    glyph(<U+0042>) |}]

let%expect_test "session finish flushes the final grapheme" =
  let result =
    let* policy = policy ()
    and* size = size 2 1
    and* lineage_id = uint 4
    and* slice = slice "A"
    and* coordinate = coord 0 0 in
    let session = Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* next =
      Result.map Tessera.session
        (with_error_kind Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes slice)))
    in
    Result.map
      (fun outcome ->
        let cells = Tessera.Renderer.cells (Tessera.outcome_snapshot outcome) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
      (with_error_kind Tessera.Session.pp_error (Tessera.finish next))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0041>) |}]
