module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json
open Tessera_test_support.Support

let print scalar =
  Model.Update.Print
    (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))

let build () =
  let* policy = policy () and* size = size 2 1 and* lineage_id = uint 3 in
  let renderer = Renderer.Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size in
  let* applied =
    with_error_kind Renderer.Renderer.pp_error
      (Renderer.Renderer.apply policy renderer (Model.Update.Batch.singleton (print 0x41)))
  in
  let snapshot = Renderer.Renderer.snapshot applied in
  with_error_kind Frame.pp_error (Frame.of_outcome ~patch:None ~snapshot)

let%expect_test "encode_html_frame produces a stable minified golden" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    with_error_kind Json.E.pp_error (Json.encode_html_frame envelope)
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect
    {| {"schema":"tessera.web-frame","version":1,"meta":{"kind":"reset","active":"primary","geometry":{"columns":2,"rows":1},"generation":"1","lineage_id":"3"},"frame":{"rows":[{"index":0,"background":[{"start":0,"width":2,"style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}],"glyphs":[{"start":0,"width":1,"text":"A","style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}]}],"cursor":{"column":1,"row":0,"visible":true,"pending_wrap":false,"style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}},"accessible_text":"A "}} |}]

let%expect_test "decode_html_frame is the inverse of encode_html_frame" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    let* text = with_error_kind Json.E.pp_error (Json.encode_html_frame envelope) in
    let* decoded = with_error_kind Json.E.pp_error (Json.decode_html_frame text) in
    Ok (decoded = envelope)
  in
  Format.printf "%a@." (pp_result Fmt.bool) result;
  [%expect {| true |}]

let%expect_test "encode_canvas_frame produces a stable minified golden" =
  let result =
    let* frame = build () in
    let envelope = Json.canvas_envelope_of frame in
    with_error_kind Json.E.pp_error (Json.encode_canvas_frame envelope)
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect
    {| {"schema":"tessera.web-frame","version":1,"meta":{"kind":"reset","active":"primary","geometry":{"columns":2,"rows":1},"generation":"1","lineage_id":"3"},"frame":{"ops":[{"op":"fill","row":0,"start":0,"width":2,"color":{"kind":"default"}},{"op":"glyph","row":0,"column":0,"text":"A","paint":{"color":{"kind":"default"},"bold":false,"italic":false,"opacity":1}},{"op":"cursor","row":0,"column":1,"visible":true,"color":{"kind":"default"}}]}} |}]

let%expect_test "decode_canvas_frame is the inverse of encode_canvas_frame" =
  let result =
    let* frame = build () in
    let envelope = Json.canvas_envelope_of frame in
    let* text = with_error_kind Json.E.pp_error (Json.encode_canvas_frame envelope) in
    let* decoded = with_error_kind Json.E.pp_error (Json.decode_canvas_frame text) in
    Ok (decoded = envelope)
  in
  Format.printf "%a@." (pp_result Fmt.bool) result;
  [%expect {| true |}]
