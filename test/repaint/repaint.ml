module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
module Terminfo = Tessera_terminfo
open Tessera_test_support.Support

let%expect_test "public facade repaints a glyph patch into terminal bytes" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage = uint 1 in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let printed =
      Renderer.Renderer.apply policy renderer
        (Model.Update.Batch.singleton
           (Model.Update.Print
              (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))))
    in
    let* applied = with_error Renderer.Renderer.E.Error.pp_kind printed in
    let target = Terminfo.Repaint.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let* target, batch =
      with_error Terminfo.Repaint.E.Error.pp_kind
        (Terminfo.Repaint.compile description policy target (Renderer.Renderer.patch applied))
    in
    let* chunks = with_error Terminfo.Encoder.E.Error.pp_kind (Terminfo.Encoder.encode description policy batch) in
    Ok (target, chunks)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Terminfo.Repaint.pp_target Terminfo.Encoder.pp_byte_chunks)) result;
  [%expect
    {|
    target(active=primary; cells=1; cursor={position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; cursor-visible=true; lineage=1; generation=1; modes={auto_wrap=true; cursor_visible=true; insert=false; origin=false}; size=2×1; title=none)
    ["\027[1;1H"; "A"; "\027[1;2H"] |}]

let%expect_test "public facade repaints a resize full projection into an owned target" =
  let result =
    let* policy = policy () and* lineage = uint 1 and* columns = uint 2 and* rows = uint 1 and* resized_rows = uint 2 in
    let* size = with_error_kind Foundation.Types.pp_error (Foundation.Types.Size.make ~columns ~rows) in
    let* resized_size =
      with_error_kind Foundation.Types.pp_error (Foundation.Types.Size.make ~columns ~rows:resized_rows)
    in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy
           (Terminfo.Terminfo.Source "demo,clear=\\E[2J,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let* applied =
      with_error Renderer.Renderer.E.Error.pp_kind
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (Model.Update.Resize resized_size)))
    in
    let target = Terminfo.Repaint.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage) ~policy ~size in
    let* target, batch =
      with_error Terminfo.Repaint.E.Error.pp_kind
        (Terminfo.Repaint.compile description policy target (Renderer.Renderer.patch applied))
    in
    let* chunks = with_error Terminfo.Encoder.E.Error.pp_kind (Terminfo.Encoder.encode description policy batch) in
    Ok (target, chunks)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Terminfo.Repaint.pp_target Terminfo.Encoder.pp_byte_chunks)) result;
  [%expect
    {|
    target(active=primary; cells=4; cursor={position=(0,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; cursor-visible=true; lineage=1; generation=1; modes={auto_wrap=true; cursor_visible=true; insert=false; origin=false}; size=2×2; title=none)
    ["\027[2J"; "\027[1;1H"; "\027[1X"; "\027[1;2H"; "\027[1X"; "\027[2;1H"; "\027[1X"; "\027[2;2H"; "\027[1X"; "\027[1;1H"] |}]

let%expect_test "public facade rejects uncontrolled repaint projections before encoding" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage = uint 1 and* zero = uint 0 in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,cup=\\E[%i%p1%d;%p2%dH,"))
    in
    let lineage_id = Foundation.Lineage_id.of_uint lineage in
    let renderer = Renderer.Renderer.initial ~lineage_id ~policy ~size in
    let bold = match Model.Style.sgr_delta 1 with Some value -> value | None -> assert false in
    let* styled =
      with_error Renderer.Renderer.E.Error.pp_kind
        (Renderer.Renderer.apply policy renderer
           (batch_of_updates
              [
                Model.Update.Set_style bold;
                Model.Update.Print
                  (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)));
                Model.Update.Set_style Model.Style.reset_delta;
              ]))
    in
    let* after_generation =
      with_error_kind Foundation.UInt.pp_error (Foundation.Generation.succ Foundation.Generation.zero)
    in
    let position =
      Foundation.Types.coord ~column:(Foundation.Types.Column.of_uint zero) ~row:(Foundation.Types.Row.of_uint zero)
    in
    let incomplete_wide =
      Renderer.Patch.make ~after_generation ~before_generation:Foundation.Generation.zero ~before_size:size
        ~cells:
          (Model.Collection.Cell_blocks.of_list
             [
               Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:position
                 ~cell:(Model.Cell.wide_continuation ~line_id:Foundation.Line_id.zero ~style:Model.Style.default);
             ])
        ~damage:Model.Collection.Damage.empty ~lineage_id
        ~presentation:
          {
            active = Renderer.Patch.Keep;
            cursor = Renderer.Patch.Keep;
            cursor_visible = Renderer.Patch.Keep;
            title = Renderer.Patch.Keep;
          }
        ~size:Renderer.Patch.Keep
    in
    let rejected target patch =
      match Terminfo.Repaint.compile description policy target patch with
      | Ok _ -> "accepted"
      | Error error -> Format.asprintf "%a" Terminfo.Repaint.E.Error.pp_kind error
    in
    let target = Terminfo.Repaint.initial ~lineage_id ~policy ~size in
    let wrong_target = Terminfo.Repaint.initial ~lineage_id:(Foundation.Lineage_id.of_uint zero) ~policy ~size in
    Ok
      ( rejected target (Renderer.Renderer.patch styled),
        rejected target incomplete_wide,
        rejected wrong_target incomplete_wide )
  in
  let pp_rejected ppf (style, wide, lineage) = Format.fprintf ppf "style=%s@.wide=%s@.lineage=%s" style wide lineage in
  Format.printf "%a@." (pp_result pp_rejected) result;
  [%expect {|
    style=unsupported presentation
    wide=incomplete wide pair
    lineage=lineage mismatch |}]
