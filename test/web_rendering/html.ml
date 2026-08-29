module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
module Frame = Tessera_web_rendering.Web_frame
module Html = Tessera_web_rendering.Web_html
open Tessera_test_support.Support

let print scalar =
  Model.Update.Print
    (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))

let%expect_test "to_html escapes reserved HTML characters in glyph text" =
  let result =
    let* policy = policy () and* size = size 3 1 and* lineage_id = uint 4 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch = batch_of_updates [ print (Char.code '<'); print (Char.code '&'); print (Char.code '"') ] in
    let* applied = with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch) in
    let snapshot = Renderer.Renderer.snapshot applied in
    let* frame = with_error_kind Frame.pp_error (Frame.of_outcome ~patch:None ~snapshot) in
    with_error_kind Html.pp_error (Html.to_html (Html.of_frame frame))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect
    {| <div class="tessera-frame" style="--tessera-columns:3;--tessera-rows:1"><div class="tessera-row" style="grid-row:1" data-row="0"><span class="tessera-bg" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg);grid-column:1 / span 3" data-start="0" data-width="3"></span><span class="tessera-glyph" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg);grid-column:1 / span 1" data-start="0" data-width="1">&lt;</span><span class="tessera-glyph" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg);grid-column:2 / span 1" data-start="1" data-width="1">&amp;</span><span class="tessera-glyph" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg);grid-column:3 / span 1" data-start="2" data-width="1">&quot;</span><span class="tessera-sr-only">&lt;&amp;&quot;</span></div><div class="tessera-cursor" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg);grid-column:3;grid-row:1" data-column="2" data-row="0" data-visible="true" data-pending-wrap="true"></div></div> |}]

(* {!Html.color_value}/{!Html.style} are public and transparent (so {!Tessera_web_rendering.Web_json} can construct
   and pattern-match them), so nothing stops a caller from hand-building one outside the closed set {!Html.of_frame}
   ever produces and calling {!Html.to_html} directly, bypassing Web_json's decode-time validation entirely.
   to_html must refuse to render such a value itself, rather than trusting its input. *)

let style ?(fg = Html.Var "--tessera-default-fg") ?(bg = Html.Var "--tessera-default-bg") ?(classes = []) () =
  { Html.fg; bg; classes }

let frame_with_cursor_style cursor_style : Html.t =
  {
    columns = 1;
    row_count = 1;
    rows = [];
    cursor = { column = 0; row = 0; visible = true; pending_wrap = false; style = cursor_style };
  }

let%expect_test "to_html rejects a hand-built hex colour smuggling extra CSS declarations" =
  let frame = frame_with_cursor_style (style ~bg:(Html.Hex "red;position:fixed;inset:0") ()) in
  let result = with_error_kind Html.pp_error (Html.to_html frame) in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-color(red;position:fixed;inset:0) |}]

let%expect_test "to_html rejects a hand-built css variable name outside the closed set" =
  let frame = frame_with_cursor_style (style ~fg:(Html.Var "--evil") ()) in
  let result = with_error_kind Html.pp_error (Html.to_html frame) in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-color(var(--evil)) |}]

let%expect_test "to_html rejects a hand-built class outside the closed set" =
  let frame = frame_with_cursor_style (style ~classes:[ "evil-class" ] ()) in
  let result = with_error_kind Html.pp_error (Html.to_html frame) in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| invalid-class("evil-class") |}]

let%expect_test "validate accepts every style Web_html.of_frame ever produces" =
  let result =
    let* policy = policy () and* size = size 3 1 and* lineage_id = uint 4 in
    let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
    let batch = batch_of_updates [ print (Char.code 'x') ] in
    let* applied = with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch) in
    let snapshot = Renderer.Renderer.snapshot applied in
    let* frame = with_error_kind Frame.pp_error (Frame.of_outcome ~patch:None ~snapshot) in
    with_error_kind Html.pp_error (Html.validate (Html.of_frame frame))
  in
  Format.printf "%a@." (pp_result (fun ppf () -> Format.pp_print_string ppf "valid")) result;
  [%expect {| valid |}]
