module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
module Web = Tessera_web_rendering.Web_frame
open Tessera_test_support.Support

let print scalar =
  Model.Update.Print
    (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))

let%expect_test "of_outcome with patch:None resets from a bare snapshot" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage_id = uint 7 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* applied =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x41)))
    in
    let snapshot = Renderer.Renderer.snapshot applied in
    with_error_kind Web.pp_error (Web.of_outcome ~patch:None ~snapshot)
  in
  Format.printf "%a@." (pp_result Web.pp) result;
  [%expect
    {|
    frame(kind=reset; rows=[row(index=0; background=[background(start=0; stop=2; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false})]; glyphs=[glyph(start=0; width=one; text="A"; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false})])]; presentation=presentation(active=primary; cursor=((1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=true; title=none; size=2×1; generation=1; lineage=7)) |}]

let summarize (frame : Web.t) = (frame.Web.kind, List.length frame.Web.rows)
let pp_summary ppf (kind, rows) = Format.fprintf ppf "kind=%a; rows=%d" Web.pp_kind kind rows

let%expect_test "of_outcome with patch:Some produces a delta for a plain edit" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage_id = uint 8 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* applied =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x41)))
    in
    let snapshot = Renderer.Renderer.snapshot applied in
    let patch = Renderer.Renderer.patch applied in
    Result.map summarize (with_error_kind Web.pp_error (Web.of_outcome ~patch:(Some patch) ~snapshot))
  in
  Format.printf "%a@." (pp_result pp_summary) result;
  [%expect {| kind=delta; rows=1 |}]

let%expect_test "of_outcome upgrades to reset on resize" =
  let result =
    let* policy = policy () and* initial_size = size 2 1 and* resized_size = size 2 2 and* lineage_id = uint 9 in
    let renderer =
      Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size
    in
    let* printed =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x41)))
    in
    let* resized =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy (Renderer.Renderer.state printed)
           (Model.Update.Batch.singleton (Model.Update.Resize resized_size)))
    in
    let snapshot = Renderer.Renderer.snapshot resized in
    let patch = Renderer.Renderer.patch resized in
    Result.map summarize (with_error_kind Web.pp_error (Web.of_outcome ~patch:(Some patch) ~snapshot))
  in
  Format.printf "%a@." (pp_result pp_summary) result;
  [%expect {| kind=reset; rows=2 |}]

let%expect_test "of_outcome upgrades to reset on alternate-screen switch" =
  let result =
    let* policy = policy () and* size = size 2 1 and* lineage_id = uint 10 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* printed =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x41)))
    in
    let* switched =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy (Renderer.Renderer.state printed)
           (Model.Update.Batch.singleton (Model.Update.Alternate_screen `Enter_1049)))
    in
    let snapshot = Renderer.Renderer.snapshot switched in
    let patch = Renderer.Renderer.patch switched in
    Result.map summarize (with_error_kind Web.pp_error (Web.of_outcome ~patch:(Some patch) ~snapshot))
  in
  Format.printf "%a@." (pp_result pp_summary) result;
  [%expect {| kind=reset; rows=1 |}]

let%expect_test "of_outcome projects a wide glyph as a single width-two instruction" =
  let result =
    let* policy = policy () and* size = size 3 1 and* lineage_id = uint 11 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* applied =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x4e00)))
    in
    let snapshot = Renderer.Renderer.snapshot applied in
    let* frame = with_error_kind Web.pp_error (Web.of_outcome ~patch:None ~snapshot) in
    Ok (List.concat_map (fun (r : Web.row) -> r.Web.glyphs) frame.Web.rows)
  in
  Format.printf "%a@." (pp_result (Fmt.list Web.pp_glyph)) result;
  [%expect
    {| glyph(start=0; width=two; text="\228\184\128"; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}) |}]

let%expect_test "of_outcome output always validates" =
  let result =
    let* policy = policy () and* size = size 3 1 and* lineage_id = uint 12 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let* applied =
      with_error_kind Renderer.Renderer.pp_error
        (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x4e00)))
    in
    let snapshot = Renderer.Renderer.snapshot applied in
    let* frame = with_error_kind Web.pp_error (Web.of_outcome ~patch:None ~snapshot) in
    with_error_kind Web.pp_error (Web.validate frame)
  in
  Format.printf "%a@." (pp_result (fun ppf () -> Format.pp_print_string ppf "valid")) result;
  [%expect {| valid |}]
