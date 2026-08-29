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
    Ok (Html.to_html (Html.of_frame frame))
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect
    {| <div class="tessera-frame"><div class="tessera-row" data-row="0"><span class="tessera-bg" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg)" data-start="0" data-width="3"></span><span class="tessera-glyph" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg)" data-start="0" data-width="1">&lt;</span><span class="tessera-glyph" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg)" data-start="1" data-width="1">&amp;</span><span class="tessera-glyph" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg)" data-start="2" data-width="1">&quot;</span></div><div class="tessera-cursor" style="--tessera-fg:var(--tessera-default-fg);--tessera-bg:var(--tessera-default-bg)" data-column="2" data-row="0" data-visible="true" data-pending-wrap="true"></div><div class="tessera-sr-only">&lt;&amp;&quot;</div></div> |}]
