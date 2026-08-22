module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let%expect_test "patch composition overlays cells and presentation" =
  let result =
    let* size = size 2 1 and* lineage = uint 1 and* coordinate = coord 0 0 and* damage = rect 0 0 0 0 in
    let* generation_one =
      with_error_kind Foundation.UInt.pp_error (Foundation.Generation.succ Foundation.Generation.zero)
    in
    let* generation_two = with_error_kind Foundation.UInt.pp_error (Foundation.Generation.succ generation_one) in
    let lineage_id = Foundation.Lineage_id.of_uint lineage in
    let cells scalar =
      Model.Collection.Cell_blocks.of_list
        [ Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:coordinate ~cell:(cell scalar) ]
    in
    let presentation title : Renderer.Patch.presentation =
      { active = Renderer.Patch.Keep; cursor = Renderer.Patch.Keep; cursor_visible = Renderer.Patch.Keep; title }
    in
    let first =
      Renderer.Patch.make ~after_generation:generation_one ~before_generation:Foundation.Generation.zero
        ~before_size:size ~cells:(cells 0x41)
        ~damage:(Model.Collection.Damage.singleton damage)
        ~lineage_id
        ~presentation:(presentation (Renderer.Patch.Set (Some "before")))
        ~size:Renderer.Patch.Keep
    in
    let second =
      Renderer.Patch.make ~after_generation:generation_two ~before_generation:generation_one ~before_size:size
        ~cells:(cells 0x42)
        ~damage:(Model.Collection.Damage.singleton damage)
        ~lineage_id
        ~presentation:(presentation (Renderer.Patch.Set (Some "after")))
        ~size:Renderer.Patch.Keep
    in
    with_error_kind Renderer.Patch.pp_error (Renderer.Patch.compose first second)
  in
  Format.printf "%a@." (pp_result Renderer.Patch.pp) result;
  [%expect
    {|
    {lineage=1; before=0; after=2; before-size=2×1; cells=[cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=0}; cells=[{contents=glyph(<U+0042>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=0}]; presentation={active=keep; cursor=keep; cursor-visible=keep; title=set(some("after"))}; size=keep} |}]

let%expect_test "renderer materializes cell damage and presentation patches" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage = uint 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let batch =
      Model.Update.Batch.append (Model.Update.Batch.singleton print)
        (Model.Update.Batch.singleton (Model.Update.Set_title "tessera"))
    in
    Result.map Renderer.Renderer.patch
      (with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Renderer.Patch.pp) result;
  [%expect
    {|
    {lineage=1; before=0; after=1; before-size=2×1; cells=[cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=0}; cells=[{contents=glyph(<U+0041>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=0}]; presentation={active=keep; cursor=set({position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}); cursor-visible=keep; title=set(some("tessera"))}; size=keep} |}]

let%expect_test "same-size resize is a full refresh and patch composition barrier" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage = uint 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let* written =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton print))
    in
    let* refreshed =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy (Renderer.Renderer.state written)
           (Model.Update.Batch.singleton (Model.Update.Resize size)))
    in
    let* composed =
      with_error_kind Renderer.Patch.pp_error
        (Renderer.Patch.compose (Renderer.Renderer.patch written) (Renderer.Renderer.patch refreshed))
    in
    Ok ((Renderer.Renderer.damage refreshed, Renderer.Patch.size composed), Renderer.Patch.cells composed)
  in
  Format.printf "%a@."
    (pp_result
       (Fmt.pair
          (Fmt.pair Renderer.Renderer.pp_damage (fun ppf -> function
            | Renderer.Patch.Keep -> Format.pp_print_string ppf "keep"
            | Renderer.Patch.Set size -> Format.fprintf ppf "set(%a)" Foundation.Types.Size.pp size))
          Model.Collection.Cell_blocks.pp))
    result;
  [%expect
    {|
    damage(cursor-changed=false; full=true; rects=[{top=0; left=0; bottom=0; right=1}])
    set(2×1)
    [cell-block(screen=alternate; rect={top=0; left=0; bottom=0; right=1}; cells=[{contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}]); cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=1}; cells=[{contents=glyph(<U+0041>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=empty; line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])] |}]

let%expect_test "renderer rejects snapshots beyond the policy limit" =
  let result =
    let* policy = policy ~max_snapshot_cells:3 () and* size = size 2 2 and* lineage = uint 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer Model.Update.Batch.empty)
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_applied) result;
  [%expect {| snapshot limit exceeded |}]

let%expect_test "renderer rejects a resize beyond the policy snapshot limit" =
  let result =
    let* policy = policy ~max_snapshot_cells:3 ()
    and* initial_size = size 1 1
    and* resized_size = size 2 2
    and* lineage = uint 1 in
    let renderer =
      Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size:initial_size
    in
    with_error_kind Renderer.Renderer.pp_error
      (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (Model.Update.Resize resized_size)))
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_applied) result;
  [%expect {| snapshot limit exceeded |}]

let%expect_test "persistent pages copy only local storage" =
  let result =
    let* grid_size = size 64 16
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 32 8 in
    let* clipped_size = size 32 8 in
    let grid = Renderer.Grid.with_blank ~size:grid_size ~line_id:Foundation.Line_id.zero ~style:Model.Style.default in
    let first = Renderer.Grid.set grid first_coord (cell 0x41) in
    let second = Renderer.Grid.set first second_coord (cell 0x42) in
    let third = Renderer.Grid.set second third_coord (cell 0x43) in
    let clipped = Renderer.Grid.resize third clipped_size in
    let statistics =
      List.map
        (fun grid ->
          let pages, copies = Renderer.Grid.stats grid in
          Format.asprintf "pages=%d copies=%d" pages copies)
        [ grid; first; second; third; clipped ]
    in
    Ok
      (String.concat "\n" statistics ^ "\nold="
      ^ Format.asprintf "%a" Model.Cell.pp_contents (Model.Cell.contents (Renderer.Grid.get grid first_coord)))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect
    {|
    pages=0 copies=0
    pages=1 copies=1
    pages=1 copies=2
    pages=2 copies=3
    pages=1 copies=3
    old=empty |}]
