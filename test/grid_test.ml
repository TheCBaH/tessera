module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer

let error_message pp error = Format.asprintf "%a" pp (Err.Error.kind error)
let with_error pp result = Result.map_error (error_message pp) result
let ( let* ) = Result.bind

let ( and* ) left right =
  let* left = left in
  let* right = right in
  Ok (left, right)

let pp_result pp = Fmt.result ~ok:pp ~error:Format.pp_print_string
let uint value = with_error Foundation.UInt.pp_error (Foundation.UInt.of_int value)

let size columns rows =
  let* columns = uint columns and* rows = uint rows in
  with_error Foundation.Types.pp_error (Foundation.Types.Size.make ~columns ~rows)

let coord column row =
  let* column = uint column and* row = uint row in
  Ok (Foundation.Types.coord ~column:(Foundation.Types.Column.of_uint column) ~row:(Foundation.Types.Row.of_uint row))

let rect left top right bottom =
  let* left = uint left and* top = uint top and* right = uint right and* bottom = uint bottom in
  with_error Foundation.Types.pp_error
    (Foundation.Types.rect ~left:(Foundation.Types.Column.of_uint left) ~top:(Foundation.Types.Row.of_uint top)
       ~right:(Foundation.Types.Column.of_uint right) ~bottom:(Foundation.Types.Row.of_uint bottom))

let cell scalar =
  Model.Cell.glyph ~line_id:Foundation.Line_id.zero ~style:Model.Style.default
    (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar))

let policy ?(max_control_bytes = 1024) ?(max_csi_params = 16) ?(max_diagnostics = 16) ?(max_snapshot_cells = 1920) () =
  let* max_columns = uint 80
  and* max_control_bytes = uint max_control_bytes
  and* max_csi_params = uint max_csi_params
  and* max_diagnostics = uint max_diagnostics
  and* max_rows = uint 24
  and* max_slice_bytes = uint 4096
  and* max_snapshot_cells = uint max_snapshot_cells in
  let* limits =
    with_error Foundation.Limits.pp_error
      (Foundation.Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows
         ~max_slice_bytes ~max_snapshot_cells)
  in
  Ok (Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)

let slice text =
  let bytes = Bytes.of_string text in
  let* off = uint 0 and* len = uint (Bytes.length bytes) in
  with_error Foundation.Types.pp_error (Foundation.Types.slice bytes ~off ~len)

let decode policy continuation text =
  let* slice = slice text in
  with_error Tessera.Decoder.pp_error (Tessera.Decoder.feed policy continuation slice)

let finish policy continuation = with_error Tessera.Decoder.pp_error (Tessera.Decoder.finish policy continuation)

let decode_chunks policy chunks =
  let rec loop continuation items = function
    | [] -> Ok (items, continuation)
    | chunk :: rest ->
        let* decoded = decode policy continuation chunk in
        loop decoded.continuation (Model.Effect.Item_sequence.append items decoded.items) rest
  in
  loop Tessera.Decoder.initial Model.Effect.Item_sequence.empty chunks

let decode_to_end policy chunks =
  let* items, continuation = decode_chunks policy chunks in
  let* finished = finish policy continuation in
  Ok (Model.Effect.Item_sequence.append items finished.items, finished.continuation)

let within_allocation_budget ~label ~maximum work =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let* _ = work () in
  let allocated = Gc.allocated_bytes () -. before in
  if allocated <= maximum then Ok label
  else Error (Format.asprintf "%s allocated %.0f bytes (budget %.0f)" label allocated maximum)

let check_decoder_splits policy text =
  let* baseline_items, _ = decode_to_end policy [ text ] in
  let length = String.length text in
  let rec loop index =
    if index > length then Ok length
    else
      let* candidate_items, _ =
        decode_to_end policy [ String.sub text 0 index; String.sub text index (length - index) ]
      in
      if candidate_items = baseline_items then loop (index + 1)
      else Error (Format.asprintf "decoder split mismatch at byte %d" index)
  in
  loop 0

let%expect_test "cell blocks and damage normalize deterministically" =
  let result =
    let* first = coord 0 0
    and* second = coord 1 0
    and* third = coord 0 1
    and* fourth = coord 1 1
    and* damage = rect 0 0 1 0
    and* overlap = rect 1 0 1 1 in
    let first_a = Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:first ~cell:(cell 0x41) in
    let first_b = Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:first ~cell:(cell 0x42) in
    let primary_second =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:second ~cell:(cell 0x44)
    in
    let primary_third =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:third ~cell:(cell 0x45)
    in
    let primary_fourth =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:fourth ~cell:(cell 0x46)
    in
    let alternate =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Alternate ~coord:second ~cell:(cell 0x43)
    in
    let blocks =
      Model.Collection.Cell_blocks.of_list
        [ first_a; alternate; primary_second; primary_third; primary_fourth; first_b ]
    in
    let damages =
      Model.Collection.Damage.union
        (Model.Collection.Damage.singleton damage)
        (Model.Collection.Damage.singleton overlap)
    in
    Ok (blocks, damages)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Model.Collection.Cell_blocks.pp Model.Collection.Damage.pp)) result;
  [%expect
    {|
    [cell-block(screen=alternate; rect={top=0; left=1; bottom=0; right=1}; cells=[{contents=glyph(<U+0043>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}]); cell-block(screen=primary; rect={top=0; left=0; bottom=1; right=1}; cells=[{contents=glyph(<U+0042>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=glyph(<U+0044>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=glyph(<U+0045>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=glyph(<U+0046>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]
    [{top=0; left=0; bottom=1; right=1}] |}]

let%expect_test "patch composition overlays cells and presentation" =
  let result =
    let* size = size 2 1 and* lineage = uint 1 and* coordinate = coord 0 0 and* damage = rect 0 0 0 0 in
    let* generation_one = with_error Foundation.UInt.pp_error (Foundation.Generation.succ Foundation.Generation.zero) in
    let* generation_two = with_error Foundation.UInt.pp_error (Foundation.Generation.succ generation_one) in
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
    with_error Renderer.Patch.pp_error (Renderer.Patch.compose first second)
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
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Renderer.Patch.pp) result;
  [%expect
    {|
    {lineage=1; before=0; after=1; before-size=2×1; cells=[cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=0}; cells=[{contents=glyph(<U+0041>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=0}]; presentation={active=keep; cursor=set({position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}); cursor-visible=keep; title=set(some("tessera"))}; size=keep} |}]

let%expect_test "renderer exposes precise local and full resize damage" =
  let result =
    let* policy = policy () and* initial_size = size 2 1 and* resized_size = size 2 2 and* lineage = uint 1 in
    let renderer =
      Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size:initial_size
    in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let* printed =
      with_error Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton print))
    in
    let* resized =
      with_error Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy (Renderer.Renderer.state printed)
           (Model.Update.Batch.singleton (Model.Update.Resize resized_size)))
    in
    Ok (Renderer.Renderer.damage printed, Renderer.Renderer.damage resized)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Renderer.Renderer.pp_damage Renderer.Renderer.pp_damage)) result;
  [%expect
    {|
    damage(cursor-changed=true; full=false; rects=[{top=0; left=0; bottom=0; right=0}])
    damage(cursor-changed=false; full=true; rects=[{top=0; left=0; bottom=1; right=1}]) |}]

let%expect_test "same-size resize is a full refresh and patch composition barrier" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage = uint 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let* written =
      with_error Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton print))
    in
    let* refreshed =
      with_error Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy (Renderer.Renderer.state written)
           (Model.Update.Batch.singleton (Model.Update.Resize size)))
    in
    let* composed =
      with_error Renderer.Patch.pp_error
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
    with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer Model.Update.Batch.empty)
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
    with_error Renderer.Renderer.pp_error
      (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (Model.Update.Resize resized_size)))
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_applied) result;
  [%expect {| snapshot limit exceeded |}]

let%expect_test "decoder diagnostics retain stream offsets and obey their budget" =
  let result =
    let* policy = policy ~max_diagnostics:2 () in
    decode policy Tessera.Decoder.initial "\007\255\027[99z"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {|
    {continuation=decoder-continuation(offset=7; diagnostics=0; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="BEL"; offset=0))); observation(diagnostic(invalid-utf8(offset=1))); update(print([<U+FFFD>]))]} |}]

let%expect_test "oversized strings discard through their terminator" =
  let first =
    let* policy = policy ~max_control_bytes:2 () in
    decode policy Tessera.Decoder.initial "\027]abc"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) first;
  let second =
    let* policy = policy ~max_control_bytes:2 () in
    let* first = first in
    decode policy first.continuation "ignored\007X"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) second;
  let final =
    let* policy = policy ~max_control_bytes:2 () in
    let* second = second in
    finish policy second.continuation
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) final;
  [%expect
    {|
    {continuation=decoder-continuation(offset=5; diagnostics=15; discard-string; utf8=empty; bytes=complete); items=[observation(diagnostic(control-string-too-long(kind="OSC"; offset=0)))]}
    {continuation=decoder-continuation(offset=14; diagnostics=15; ground; utf8=pending(<U+0058>); bytes=complete); items=[]}
    {continuation=decoder-continuation(offset=14; diagnostics=15; ground; utf8=empty; bytes=complete); items=[update(print([<U+0058>]))]} |}]

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

let%expect_test "snapshot materializes the active grid" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage_id = uint 1 and* coordinate = coord 0 0 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch =
      Model.Update.Batch.singleton
        (Model.Update.Print
           (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0041>) |}]

let%expect_test "snapshot exposes presentation and restored origin state" =
  let result =
    let* policy = policy ()
    and* size = size 4 4
    and* lineage_id = uint 2
    and* top = uint 1
    and* bottom = uint 2
    and* column = uint 0
    and* row = uint 0 in
    let* origin = Option.to_result ~none:"origin mode is unavailable" (Model.Mode.private_mode_delta ~enabled:true 6) in
    let* origin_disabled =
      Option.to_result ~none:"origin mode is unavailable" (Model.Mode.private_mode_delta ~enabled:false 6)
    in
    let* cursor_hidden =
      Option.to_result ~none:"cursor visibility mode is unavailable" (Model.Mode.private_mode_delta ~enabled:false 25)
    in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch =
      List.fold_left
        (fun batch operation -> Model.Update.Batch.append batch (Model.Update.Batch.singleton operation))
        Model.Update.Batch.empty
        [
          Model.Update.Set_margins
            { top = Foundation.Types.Row.of_uint top; bottom = Foundation.Types.Row.of_uint bottom };
          Model.Update.Set_mode origin;
          Model.Update.Move_cursor
            (Model.Update.Position
               (Foundation.Types.coord
                  ~column:(Foundation.Types.Column.of_uint column)
                  ~row:(Foundation.Types.Row.of_uint row)));
          Model.Update.Save_cursor;
          Model.Update.Set_mode cursor_hidden;
          Model.Update.Set_mode origin_disabled;
          Model.Update.Move_cursor (Model.Update.Down Foundation.UInt.max_value);
          Model.Update.Restore_cursor;
          Model.Update.Move_cursor (Model.Update.Down Foundation.UInt.max_value);
          Model.Update.Set_title "tessera";
        ]
    in
    Result.map Renderer.Renderer.snapshot
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_snapshot) result;
  [%expect
    {| snapshot(active=primary; cursor=((0,2); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=false; lineage=2; generation=1; size=4×4; title=some("tessera")) |}]

let%expect_test "renderer writes wide cells and wraps before the following glyph" =
  let result =
    let* policy = policy ()
    and* size = size 3 2
    and* lineage_id = uint 3
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 2 0
    and* fourth_coord = coord 0 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x4e00))
           (Model.Update.Batch.singleton (print 0x42)))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord; fourth_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+4E00>)
    wide-continuation
    glyph(<U+0042>) |}]

let%expect_test "renderer repairs wide cells touched by character edits" =
  let result =
    let* policy = policy ()
    and* size = size 3 1
    and* lineage_id = uint 3
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 2 0
    and* count = uint 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x4e00))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position first_coord)))
           (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Erase_chars count))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    empty
    empty
    empty |}]

let%expect_test "renderer scrolls immutable grids" =
  let result =
    let* policy = policy ()
    and* size = size 2 2
    and* lineage_id = uint 5
    and* count = uint 1
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 0 1
    and* fourth_coord = coord 1 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (print 0x44))
                 (Model.Update.Batch.singleton (Model.Update.Scroll_up count)))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord; fourth_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0043>)
    glyph(<U+0044>)
    empty
    empty |}]

let%expect_test "renderer honors disabled auto-wrap" =
  let result =
    let* policy = policy ()
    and* size = size 2 2
    and* lineage_id = uint 6
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0 in
    let* auto_wrap = Option.to_result ~none:"missing auto-wrap mode" (Model.Mode.private_mode_delta ~enabled:false 7) in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Set_mode auto_wrap))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x41))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x42))
              (Model.Update.Batch.singleton (print 0x43))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0043>) |}]

let%expect_test "renderer erases display cells" =
  let result =
    let* policy = policy ()
    and* size = size 2 2
    and* lineage_id = uint 7
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 0 1
    and* fourth_coord = coord 1 1 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (print 0x44))
                 (Model.Update.Batch.append
                    (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position first_coord)))
                    (Model.Update.Batch.singleton (Model.Update.Erase (Model.Update.Display `Clear_below)))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord; fourth_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    empty
    empty
    empty
    empty |}]

let%expect_test "renderer edits characters in the active row" =
  let result =
    let* policy = policy ()
    and* size = size 3 1
    and* lineage_id = uint 8
    and* count = uint 1
    and* first_coord = coord 0 0
    and* second_coord = coord 1 0
    and* third_coord = coord 2 0 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position second_coord)))
                 (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Delete_chars count))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0043>)
    empty |}]

let%expect_test "renderer deletes active-screen lines" =
  let result =
    let* policy = policy ()
    and* size = size 1 3
    and* lineage_id = uint 9
    and* count = uint 1
    and* first_coord = coord 0 0
    and* second_coord = coord 0 1
    and* third_coord = coord 0 2 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (print 0x41))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (print 0x42))
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (print 0x43))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position second_coord)))
                 (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Delete_lines count))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0043>)
    empty |}]

let%expect_test "renderer scrolls and positions inside explicit margins" =
  let result =
    let* policy = policy ()
    and* size = size 1 4
    and* lineage_id = uint 10
    and* first_coord = coord 0 0
    and* second_coord = coord 0 1
    and* third_coord = coord 0 2
    and* fourth_coord = coord 0 3 in
    let* origin_mode = Option.to_result ~none:"missing origin mode" (Model.Mode.private_mode_delta ~enabled:true 6) in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let margins = { Model.Update.top = second_coord.row; bottom = third_coord.row } in
    let at coordinate update =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position coordinate)))
        (Model.Update.Batch.singleton update)
    in
    let batch =
      Model.Update.Batch.append
        (at first_coord (print 0x41))
        (Model.Update.Batch.append
           (at second_coord (print 0x42))
           (Model.Update.Batch.append
              (at third_coord (print 0x43))
              (Model.Update.Batch.append
                 (at fourth_coord (print 0x44))
                 (Model.Update.Batch.append
                    (Model.Update.Batch.singleton (Model.Update.Set_margins margins))
                    (Model.Update.Batch.append
                       (Model.Update.Batch.singleton (Model.Update.Set_mode origin_mode))
                       (Model.Update.Batch.append
                          (at second_coord (print 0x58))
                          (Model.Update.Batch.singleton (print 0x59))))))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        List.map
          (fun coordinate -> Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
          [ first_coord; second_coord; third_coord; fourth_coord ])
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result (Fmt.vbox (Fmt.list ~sep:Fmt.cut Model.Cell.pp_contents))) result;
  [%expect {|
    glyph(<U+0041>)
    glyph(<U+0058>)
    glyph(<U+0059>)
    glyph(<U+0044>) |}]

let%expect_test "renderer uses configured tab stops" =
  let result =
    let* policy = policy ()
    and* size = size 10 1
    and* lineage_id = uint 11
    and* count = uint 1
    and* origin = coord 0 0
    and* target = coord 1 0 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x58)))
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Forward count)))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton Model.Update.Set_tab)
           (Model.Update.Batch.append
              (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Column origin.column)))
              (Model.Update.Batch.append
                 (Model.Update.Batch.singleton Model.Update.Horizontal_tab)
                 (Model.Update.Batch.singleton print))))
    in
    Result.map
      (fun applied ->
        let cells = Renderer.Renderer.cells (Renderer.Renderer.snapshot applied) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells target))
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0058>) |}]

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
      (with_error Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes slice)))
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
    let* pending = with_error Tessera.Session.pp_error (Tessera.ingest initial (Tessera.Bytes slice)) in
    let* resized =
      with_error Tessera.Session.pp_error
        (Tessera.ingest (Tessera.session pending) (Tessera.Out_of_band (Tessera.Resize size)))
    in
    let* finished = with_error Tessera.Session.pp_error (Tessera.finish (Tessera.session resized)) in
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
    let* pending_first = with_error Tessera.Session.pp_error (Tessera.ingest initial (Tessera.Bytes first_slice)) in
    let* first = with_error Tessera.Session.pp_error (Tessera.finish (Tessera.session pending_first)) in
    let* pending_second =
      with_error Tessera.Session.pp_error (Tessera.ingest (Tessera.session first) (Tessera.Bytes second_slice))
    in
    let* second = with_error Tessera.Session.pp_error (Tessera.finish (Tessera.session pending_second)) in
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

let%expect_test "a warmed local renderer update stays within its allocation budget" =
  let result =
    let* policy = policy () and* size = size 80 24 and* lineage_id = uint 6 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))
    in
    let work () =
      with_error Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton print))
    in
    within_allocation_budget ~label:"local renderer update within budget" ~maximum:2_000_000. work
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| local renderer update within budget |}]

let%expect_test "decoder maps fragmented ESC CSI sequences" =
  let result =
    let* policy = policy () in
    let* first = decode policy Tessera.Decoder.initial "\027[2;" in
    decode policy first.continuation "3H\027[2J\027[1;3;24m"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=19; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(move-cursor(position((2,1)))); update(erase(display(clear-all))); update(set-style({ background=keep; bold=true; faint=keep; foreground=keep; invisible=keep; inverse=keep; italic=true; strikethrough=keep; underline=false }))]} |}]

let%expect_test "decoder chunking preserves mixed text and control output" =
  let result =
    let* policy = policy () in
    let text = "A\xc3\xa9\027[2;3H\027]2;tessera\007" in
    let* whole = decode policy Tessera.Decoder.initial text in
    let* chunked = decode_chunks policy [ "A\xc3"; "\xa9\027[2"; ";3H\027]2"; ";tessera\007" ] in
    Ok ((whole.items, whole.continuation), chunked)
  in
  let pp_output = Fmt.pair Model.Effect.Item_sequence.pp Tessera.Decoder.pp in
  Format.printf "%a@." (pp_result (Fmt.pair pp_output pp_output)) result;
  [%expect
    {|
    [update(print([<U+0041>])); update(print([<U+00E9>])); update(move-cursor(position((2,1)))); update(set-title("tessera"))]
    decoder-continuation(offset=21; diagnostics=16; ground; utf8=empty; bytes=complete)
    [update(print([<U+0041>])); update(print([<U+00E9>])); update(move-cursor(position((2,1)))); update(set-title("tessera"))]
    decoder-continuation(offset=21; diagnostics=16; ground; utf8=empty; bytes=complete) |}]

let%expect_test "decoder preserves every split point of a mixed fixture" =
  let result =
    let* policy = policy () in
    check_decoder_splits policy "A\xc3\xa9\027[2;3H\027]2;tessera\007"
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.int ~error:Format.pp_print_string) result;
  [%expect {| 21 |}]

let%expect_test "decoder maps CSI line-relative cursor moves" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[2E\027[F"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=7; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(move-cursor(next-line(2))); update(move-cursor(previous-line(1)))]} |}]

let%expect_test "decoder maps C0, ESC, and CSI editing operations" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial
      "\b\t\n\
       \011\012\r\0277\0278\027D\027M\027E\027H\027c\027[2A\027[2B\027[2C\027[2D\027[2G\027[2d\027[2J\027[1K\027[2X\027[2P\027[2@\027[2L\027[2M\027[2S\027[2T"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=80; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(backspace); update(horizontal-tab); update(line-feed); update(line-feed); update(line-feed); update(carriage-return); update(save-cursor); update(restore-cursor); update(scroll-up(1)); update(scroll-down(1)); update(carriage-return); update(line-feed); update(set-tab); update(reset); update(move-cursor(up(2))); update(move-cursor(down(2))); update(move-cursor(forward(2))); update(move-cursor(back(2))); update(move-cursor(column(1))); update(move-cursor(row(1))); update(erase(display(clear-all))); update(erase(line(clear-left))); update(edit(erase-chars(2))); update(edit(delete-chars(2))); update(edit(insert-chars(2))); update(edit(insert-lines(2))); update(edit(delete-lines(2))); update(scroll-up(2)); update(scroll-down(2))]} |}]

let%expect_test "decoder maps DEC private modes" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[?6;7;25l"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=10; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-mode({auto_wrap=false; cursor_visible=false; insert=keep; origin=false}))]} |}]

let%expect_test "decoder maps indexed and RGB SGR colours" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[31;48;5;42;38;2;1;2;3m"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=24; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-style({ background=indexed(42); bold=keep; faint=keep; foreground=rgb(1,2,3); invisible=keep; inverse=keep; italic=keep; strikethrough=keep; underline=keep }))]} |}]

let%expect_test "decoder discards CSI sequences above the parameter limit" =
  let result =
    let* policy = policy ~max_csi_params:2 () in
    decode policy Tessera.Decoder.initial "\027[1;2;3A"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=8; diagnostics=15; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(malformed-csi(offset=0; reason="parameter count exceeds policy")))]} |}]

let%expect_test "decoder rejects overflowing CSI parameters" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[999999999999999999999999A"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=27; diagnostics=15; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="CSI"; offset=0)))]} |}]

let%expect_test "decoder switches the alternate screen through DEC modes" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[?1049h\027[?1049l"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=16; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(alternate-screen(enter-1049)); update(alternate-screen(leave-1049))]} |}]

let%expect_test "renderer restores the primary cursor around DEC 1049" =
  let result =
    let* policy = policy () and* size = size 3 1 and* lineage_id = uint 3 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let print scalar =
      Model.Update.Print
        (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))
    in
    let batch =
      List.fold_left
        (fun batch operation -> Model.Update.Batch.append batch (Model.Update.Batch.singleton operation))
        Model.Update.Batch.empty
        [ print 0x41; Model.Update.Alternate_screen `Enter_1049; print 0x42; Model.Update.Alternate_screen `Leave_1049 ]
    in
    Result.map Renderer.Renderer.snapshot
      (with_error Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch))
  in
  Format.printf "%a@." (pp_result Renderer.Renderer.pp_snapshot) result;
  [%expect
    {| snapshot(active=primary; cursor=((1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=true; lineage=3; generation=1; size=3×1; title=none) |}]

let%expect_test "decoder maps CSI cursor save and restore" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[s\027[u"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=6; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(save-cursor); update(restore-cursor)]} |}]

let%expect_test "decoder maps standard insert mode" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[4h\027[4l"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=8; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-mode({auto_wrap=keep; cursor_visible=keep; insert=true; origin=keep})); update(set-mode({auto_wrap=keep; cursor_visible=keep; insert=false; origin=keep}))]} |}]

let%expect_test "decoder maps explicit scrolling margins" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027[2;3r"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=6; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-margins({top=1; bottom=2}))]} |}]

let%expect_test "session finish flushes the final grapheme" =
  let result =
    let* policy = policy ()
    and* size = size 2 1
    and* lineage_id = uint 4
    and* slice = slice "A"
    and* coordinate = coord 0 0 in
    let session = Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* next =
      Result.map Tessera.session (with_error Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes slice)))
    in
    Result.map
      (fun outcome ->
        let cells = Tessera.Renderer.cells (Tessera.outcome_snapshot outcome) in
        Model.Cell.contents (Model.Collection.Snapshot_cells.get cells coordinate))
      (with_error Tessera.Session.pp_error (Tessera.finish next))
  in
  Format.printf "%a@." (pp_result Model.Cell.pp_contents) result;
  [%expect {| glyph(<U+0041>) |}]

let%expect_test "decoder preserves fragmented UTF-8 through EOF" =
  let partial =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\xc3"
  in
  let complete =
    let* policy = policy () in
    let* partial = partial in
    decode policy partial.continuation "\xa9"
  in
  let final =
    let* complete = complete in
    let* policy = policy () in
    with_error Tessera.Decoder.pp_error (Tessera.Decoder.finish policy complete.continuation)
  in
  Format.printf "partial=%a@.complete=%a@.final=%a@." (pp_result Tessera.Decoder.pp_decoded) partial
    (pp_result Tessera.Decoder.pp_decoded) complete (pp_result Tessera.Decoder.pp_decoded) final;
  [%expect
    {|
    partial={continuation=decoder-continuation(offset=1; diagnostics=16; ground; utf8=empty; bytes=partial); items=[]}
    complete={continuation=decoder-continuation(offset=2; diagnostics=16; ground; utf8=pending(<U+00E9>); bytes=complete); items=[]}
    final={continuation=decoder-continuation(offset=2; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(print([<U+00E9>]))]} |}]

let%expect_test "decoder frames OSC titles" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027]2;tessera\007"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=12; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-title("tessera"))]} |}]

let%expect_test "decoder accepts fragmented OSC string terminators" =
  let first =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027]0;tessera\027"
  in
  let second =
    let* policy = policy () in
    let* first = first in
    decode policy first.continuation "\\"
  in
  Format.printf "first=%a@.second=%a@." (pp_result Tessera.Decoder.pp_decoded) first
    (pp_result Tessera.Decoder.pp_decoded) second;
  [%expect
    {|
    first={continuation=decoder-continuation(offset=12; diagnostics=16; osc; utf8=empty; bytes=complete); items=[]}
    second={continuation=decoder-continuation(offset=13; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-title("tessera"))]} |}]

let%expect_test "decoder accepts C1 control string framing" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\x9d2;tessera\x9c\x90ignored\x9c"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=20; diagnostics=15; ground; utf8=empty; bytes=complete); items=[update(set-title("tessera")); observation(diagnostic(unsupported-sequence(family="DCS"; offset=11)))]} |}]

let%expect_test "decoder maps C1 single controls" =
  let result =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\x84\x85\x88\x8d"
  in
  Format.printf "%a@." (pp_result Tessera.Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=4; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(scroll-up(1)); update(carriage-return); update(line-feed); update(set-tab); update(scroll-down(1))]} |}]

let%expect_test "decoder frames fragmented SOS strings" =
  let first =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\x98ignored\027"
  in
  let second =
    let* policy = policy () in
    let* first = first in
    decode policy first.continuation "\\A"
  in
  let finished =
    let* policy = policy () in
    let* second = second in
    finish policy second.continuation
  in
  Format.printf "first=%a@.second=%a@.finished=%a@." (pp_result Tessera.Decoder.pp_decoded) first
    (pp_result Tessera.Decoder.pp_decoded) second (pp_result Tessera.Decoder.pp_decoded) finished;
  [%expect
    {|
    first={continuation=decoder-continuation(offset=9; diagnostics=15; discard-string; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="SOS"; offset=0)))]}
    second={continuation=decoder-continuation(offset=11; diagnostics=15; ground; utf8=pending(<U+0041>); bytes=complete); items=[]}
    finished={continuation=decoder-continuation(offset=11; diagnostics=15; ground; utf8=empty; bytes=complete); items=[update(print([<U+0041>]))]} |}]

let%expect_test "decoder cancellation discards incomplete OSC and CSI" =
  let decoded =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027]2;ignored\024A\027[12\026B"
  in
  let finished =
    let* policy = policy () in
    let* decoded = decoded in
    finish policy decoded.continuation
  in
  Format.printf "decoded=%a@.finished=%a@." (pp_result Tessera.Decoder.pp_decoded) decoded
    (pp_result Tessera.Decoder.pp_decoded) finished;
  [%expect
    {|
    decoded={continuation=decoder-continuation(offset=19; diagnostics=16; ground; utf8=pending(<U+0042>); bytes=complete); items=[update(print([<U+0041>]))]}
    finished={continuation=decoder-continuation(offset=19; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(print([<U+0042>]))]} |}]

let%expect_test "decoder reports unterminated control strings only at EOF" =
  let decoded =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027]2;unterminated"
  in
  let finished =
    let* policy = policy () in
    let* decoded = decoded in
    finish policy decoded.continuation
  in
  Format.printf "decoded=%a@.finished=%a@." (pp_result Tessera.Decoder.pp_decoded) decoded
    (pp_result Tessera.Decoder.pp_decoded) finished;
  [%expect
    {|
    decoded={continuation=decoder-continuation(offset=16; diagnostics=16; osc; utf8=empty; bytes=complete); items=[]}
    finished={continuation=decoder-continuation(offset=16; diagnostics=15; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="OSC"; offset=0)))]} |}]

let%expect_test "decoder frames unsupported control strings" =
  let decoded =
    let* policy = policy () in
    decode policy Tessera.Decoder.initial "\027Pdcs\027\\\027_apc\027\\\027^pm\027\\A"
  in
  let finished =
    let* policy = policy () in
    let* decoded = decoded in
    with_error Tessera.Decoder.pp_error (Tessera.Decoder.finish policy decoded.continuation)
  in
  Format.printf "decoded=%a@.finished=%a@." (pp_result Tessera.Decoder.pp_decoded) decoded
    (pp_result Tessera.Decoder.pp_decoded) finished;
  [%expect
    {|
    decoded={continuation=decoder-continuation(offset=21; diagnostics=13; ground; utf8=pending(<U+0041>); bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="DCS"; offset=0))); observation(diagnostic(unsupported-sequence(family="APC"; offset=7))); observation(diagnostic(unsupported-sequence(family="PM"; offset=14)))]}
    finished={continuation=decoder-continuation(offset=21; diagnostics=13; ground; utf8=empty; bytes=complete); items=[update(print([<U+0041>]))]} |}]

let%expect_test "Unicode graphemes remain stable across boundaries" =
  let result =
    let* policy = policy () in
    let feed continuation scalar =
      with_error Model.Unicode.pp_error (Model.Unicode.feed policy continuation (Uchar.of_int scalar))
    in
    let* continuation, first = feed Model.Unicode.initial 0x61 in
    let* continuation, second = feed continuation 0x301 in
    let* continuation, completed = feed continuation 0x62 in
    let* final = with_error Model.Unicode.pp_error (Model.Unicode.finish policy continuation) in
    Ok (first, second, completed, final)
  in
  let pp_graphemes ppf (first, second, completed, final) =
    Format.fprintf ppf "first=%a@.second=%a@.completed=%a@.final=%a@.wide=%a@.combining=%a@."
      Model.Unicode.Grapheme_sequence.pp first Model.Unicode.Grapheme_sequence.pp second
      Model.Unicode.Grapheme_sequence.pp completed Model.Unicode.Grapheme_sequence.pp final Model.Unicode.pp_width
      (Model.Unicode.width (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x4e00)))
      Model.Unicode.pp_width
      (Model.Unicode.width (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x301)))
  in
  Format.printf "%a" (pp_result pp_graphemes) result;
  [%expect
    {|
    first=[]
    second=[]
    completed=[<U+0061U+0301>]
    final=[<U+0062>]
    wide=two
    combining=zero |}]
