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
    {| {"schema":"tessera.web-frame","version":1,"target":"html","meta":{"kind":"reset","active":"primary","geometry":{"columns":2,"rows":1},"generation":"1","lineage_id":"3"},"frame":{"columns":2,"row_count":1,"rows":[{"index":0,"background":[{"start":0,"width":2,"style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}],"glyphs":[{"start":0,"width":1,"text":"A","style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}],"text":"A "}],"cursor":{"column":1,"row":0,"visible":true,"pending_wrap":false,"style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}}} |}]

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
    {| {"schema":"tessera.web-frame","version":1,"target":"canvas","meta":{"kind":"reset","active":"primary","geometry":{"columns":2,"rows":1},"generation":"1","lineage_id":"3"},"frame":{"ops":[{"op":"fill","row":0,"start":0,"width":2,"color":{"kind":"default"}},{"op":"glyph","row":0,"width":1,"column":0,"text":"A","paint":{"color":{"kind":"default"},"bold":false,"italic":false,"opacity":1}},{"op":"cursor","row":0,"column":1,"visible":true,"color":{"kind":"default"}}]}} |}]

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

(* --- decode rejects mismatched/untrusted wire content ---

   Each case starts from a known-valid golden and substitutes exactly the substring under test, so
   the rest of the envelope stays structurally valid (decode order builds the whole record before
   the envelope-level schema/version/target check runs, and per-field validation runs where its
   field is decoded). *)

let replace ~sub ~by s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  let rec find i =
    if i + sub_len > s_len then None else if String.sub s i sub_len = sub then Some i else find (i + 1)
  in
  match find 0 with
  | None -> failwith (Printf.sprintf "substring %S not found in %S" sub s)
  | Some i -> String.sub s 0 i ^ by ^ String.sub s (i + sub_len) (s_len - i - sub_len)

let golden_html () =
  let* frame = build () in
  with_error_kind Json.E.pp_error (Json.encode_html_frame (Json.html_envelope_of frame))

let check_rejected name mutated =
  let result = Json.decode_html_frame mutated in
  Format.printf "%s: %a@." name Fmt.bool (Result.is_error result)

let%expect_test "decode_html_frame rejects an unknown schema" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"schema":"tessera.web-frame"|} ~by:{|"schema":"bogus"|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-schema" mutated | Error e -> print_string e);
  [%expect {| bad-schema: true |}]

let%expect_test "decode_html_frame rejects an unsupported version" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"version":1|} ~by:{|"version":2|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-version" mutated | Error e -> print_string e);
  [%expect {| bad-version: true |}]

let%expect_test "decode_html_frame rejects the wrong target discriminator" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"target":"html"|} ~by:{|"target":"canvas"|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-target" mutated | Error e -> print_string e);
  [%expect {| bad-target: true |}]

let%expect_test "decode_html_frame rejects a css variable name outside the closed set" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"name":"--tessera-default-fg"|} ~by:{|"name":"--evil"|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-css-var" mutated | Error e -> print_string e);
  [%expect {| bad-css-var: true |}]

let%expect_test "decode_html_frame rejects a malformed hex colour" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|{"kind":"var","name":"--tessera-default-fg"}|} ~by:{|{"kind":"hex","value":"#zzzzzz"}|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-hex" mutated | Error e -> print_string e);
  [%expect {| bad-hex: true |}]

let%expect_test "decode_html_frame rejects a css class outside the closed set" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"classes":[]|} ~by:{|"classes":["evil-class"]|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-class" mutated | Error e -> print_string e);
  [%expect {| bad-class: true |}]

let%expect_test "decode_html_frame rejects a css palette index outside 0..255" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"name":"--tessera-default-fg"|} ~by:{|"name":"--tessera-color-999"|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-palette-range" mutated | Error e -> print_string e);
  [%expect {| bad-palette-range: true |}]

let%expect_test "decode_html_frame rejects negative frame geometry" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"columns":2,"row_count":1|} ~by:{|"columns":-2,"row_count":1|} golden)
  in
  (match result with Ok mutated -> check_rejected "negative-columns" mutated | Error e -> print_string e);
  [%expect {| negative-columns: true |}]

let%expect_test "decode_html_frame rejects a frame geometry disagreeing with envelope metadata" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"columns":2,"row_count":1|} ~by:{|"columns":3,"row_count":1|} golden)
  in
  (match result with Ok mutated -> check_rejected "geometry-mismatch" mutated | Error e -> print_string e);
  [%expect {| geometry-mismatch: true |}]

let%expect_test "decode_html_frame rejects a row index outside the frame's size" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"index":0|} ~by:{|"index":5|} golden)
  in
  (match result with Ok mutated -> check_rejected "row-out-of-range" mutated | Error e -> print_string e);
  [%expect {| row-out-of-range: true |}]

let%expect_test "decode_html_frame rejects a negative background span start" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"start":0,"width":2|} ~by:{|"start":-1,"width":2|} golden)
  in
  (match result with Ok mutated -> check_rejected "negative-span-start" mutated | Error e -> print_string e);
  [%expect {| negative-span-start: true |}]

let%expect_test "decode_html_frame rejects a span start so large that start + width overflows" =
  (* max_int (native 63-bit) as [start]: a naive [start + width <= columns] check wraps this negative and would
     wrongly pass. [fits_within]'s [start <= columns] catches it without computing the sum. *)
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"start":0,"width":2|} ~by:{|"start":4611686018427387903,"width":1|} golden)
  in
  (match result with Ok mutated -> check_rejected "overflow-span-start" mutated | Error e -> print_string e);
  [%expect {| overflow-span-start: true |}]

let%expect_test "decode_html_frame rejects a glyph span extending past the row's columns" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"start":0,"width":1,"text":"A"|} ~by:{|"start":5,"width":1,"text":"A"|} golden)
  in
  (match result with Ok mutated -> check_rejected "glyph-out-of-range" mutated | Error e -> print_string e);
  [%expect {| glyph-out-of-range: true |}]

let%expect_test "decode_html_frame rejects a cursor position outside the frame's size" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"column":1,"row":0,"visible":true|} ~by:{|"column":5,"row":0,"visible":true|} golden)
  in
  (match result with Ok mutated -> check_rejected "cursor-out-of-range" mutated | Error e -> print_string e);
  [%expect {| cursor-out-of-range: true |}]

let%expect_test "decode_html_frame rejects an empty background list on a reset row" =
  (* The protocol requires a row's background spans to tile every column, including plain/blank ones -- a decoder
     that only checks coordinate validity would accept an empty list here since [List.for_all] over [] is true. *)
  let result =
    let* golden = golden_html () in
    Ok
      (replace
         ~sub:
           {|"background":[{"start":0,"width":2,"style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}]|}
         ~by:{|"background":[]|} golden)
  in
  (match result with Ok mutated -> check_rejected "empty-background" mutated | Error e -> print_string e);
  [%expect {| empty-background: true |}]

let html_row_json =
  {|{"index":0,"background":[{"start":0,"width":2,"style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}],"glyphs":[{"start":0,"width":1,"text":"A","style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}],"text":"A "}|}

let widen_html_geometry g =
  replace ~sub:{|"columns":2,"row_count":1|} ~by:{|"columns":2,"row_count":2|} g
  |> replace ~sub:{|"geometry":{"columns":2,"rows":1}|} ~by:{|"geometry":{"columns":2,"rows":2}|}

let%expect_test "decode_html_frame rejects a tiny payload declaring an enormous row_count without allocating" =
  (* row_count/rows near max_int: a decoder that allocates a scratch array sized directly from the declared
     geometry (e.g. [Array.make row_count false]) would raise [Invalid_argument] here (or exhaust memory for a
     smaller-but-still-huge value) instead of returning an ordinary decode error. This must fail fast. *)
  let result =
    let* golden = golden_html () in
    Ok
      (replace ~sub:{|"columns":2,"row_count":1|} ~by:{|"columns":2,"row_count":4611686018427387903|} golden
      |> replace ~sub:{|"geometry":{"columns":2,"rows":1}|} ~by:{|"geometry":{"columns":2,"rows":4611686018427387903}|}
      )
  in
  (match result with Ok mutated -> check_rejected "huge-row-count" mutated | Error e -> print_string e);
  [%expect {| huge-row-count: true |}]

let%expect_test "decode_html_frame rejects two rows sharing the same index" =
  (* Widen the frame to row_count=2 (agreeing with meta.geometry, so this isolates the uniqueness check from the
     geometry-agreement one) and duplicate the sole row -- both copies claim index 0. *)
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:html_row_json ~by:(html_row_json ^ "," ^ html_row_json) (widen_html_geometry golden))
  in
  (match result with Ok mutated -> check_rejected "duplicate-row-index" mutated | Error e -> print_string e);
  [%expect {| duplicate-row-index: true |}]

let%expect_test "decode_html_frame rejects a reset frame missing a row" =
  let result =
    let* golden = golden_html () in
    Ok (widen_html_geometry golden)
  in
  (match result with Ok mutated -> check_rejected "incomplete-reset" mutated | Error e -> print_string e);
  [%expect {| incomplete-reset: true |}]

let%expect_test "decode_html_frame rejects two overlapping glyphs on the same row" =
  let glyph_json =
    {|{"start":0,"width":1,"text":"A","style":{"fg":{"kind":"var","name":"--tessera-default-fg"},"bg":{"kind":"var","name":"--tessera-default-bg"},"classes":[]}}|}
  in
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:glyph_json ~by:(glyph_json ^ "," ^ glyph_json) golden)
  in
  (match result with Ok mutated -> check_rejected "glyph-overlap" mutated | Error e -> print_string e);
  [%expect {| glyph-overlap: true |}]

let golden_canvas () =
  let* frame = build () in
  with_error_kind Json.E.pp_error (Json.encode_canvas_frame (Json.canvas_envelope_of frame))

let check_rejected_canvas name mutated =
  let result = Json.decode_canvas_frame mutated in
  Format.printf "%s: %a@." name Fmt.bool (Result.is_error result)

let%expect_test "decode_canvas_frame rejects an indexed colour outside 0..255" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|{"kind":"default"}|} ~by:{|{"kind":"indexed","index":999}|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "bad-indexed" mutated | Error e -> print_string e);
  [%expect {| bad-indexed: true |}]

let%expect_test "decode_canvas_frame rejects an rgb component outside 0..255" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|{"kind":"default"}|} ~by:{|{"kind":"rgb","r":999,"g":0,"b":0}|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "bad-rgb" mutated | Error e -> print_string e);
  [%expect {| bad-rgb: true |}]

let%expect_test "decode_canvas_frame rejects an opacity outside 0..1" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|"opacity":1|} ~by:{|"opacity":2|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "bad-opacity" mutated | Error e -> print_string e);
  [%expect {| bad-opacity: true |}]

let%expect_test "decode_canvas_frame rejects a fill start so large that start + width overflows" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|"start":0,"width":2|} ~by:{|"start":4611686018427387903,"width":1|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "overflow-fill-start" mutated | Error e -> print_string e);
  [%expect {| overflow-fill-start: true |}]

let%expect_test "decode_canvas_frame rejects a negative op row" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|"op":"fill","row":0|} ~by:{|"op":"fill","row":-1|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "negative-row" mutated | Error e -> print_string e);
  [%expect {| negative-row: true |}]

let%expect_test "decode_canvas_frame rejects an op column outside the envelope's geometry" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|"column":0,"text":"A"|} ~by:{|"column":9,"text":"A"|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "column-out-of-range" mutated | Error e -> print_string e);
  [%expect {| column-out-of-range: true |}]

let%expect_test "decode_canvas_frame rejects an empty ops list on a reset" =
  (* The protocol requires background Fill coverage for every row of a reset -- a decoder that only checks
     coordinate validity would accept [ops: []] since [List.for_all] over [] is true. *)
  let result =
    let* golden = golden_canvas () in
    Ok
      (replace
         ~sub:
           {|"ops":[{"op":"fill","row":0,"start":0,"width":2,"color":{"kind":"default"}},{"op":"glyph","row":0,"width":1,"column":0,"text":"A","paint":{"color":{"kind":"default"},"bold":false,"italic":false,"opacity":1}},{"op":"cursor","row":0,"column":1,"visible":true,"color":{"kind":"default"}}]|}
         ~by:{|"ops":[]|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "empty-ops" mutated | Error e -> print_string e);
  [%expect {| empty-ops: true |}]

let%expect_test "decode_canvas_frame rejects a fill that does not tile its row" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|"start":0,"width":2|} ~by:{|"start":0,"width":1|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "partial-fill" mutated | Error e -> print_string e);
  [%expect {| partial-fill: true |}]

let%expect_test "decode_canvas_frame rejects two overlapping glyphs on the same row" =
  let glyph_json =
    {|{"op":"glyph","row":0,"width":1,"column":0,"text":"A","paint":{"color":{"kind":"default"},"bold":false,"italic":false,"opacity":1}}|}
  in
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:glyph_json ~by:(glyph_json ^ "," ^ glyph_json) golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "glyph-overlap" mutated | Error e -> print_string e);
  [%expect {| glyph-overlap: true |}]

let%expect_test "decode_canvas_frame rejects a reset frame missing background coverage for a row" =
  let result =
    let* golden = golden_canvas () in
    Ok (replace ~sub:{|"geometry":{"columns":2,"rows":1}|} ~by:{|"geometry":{"columns":2,"rows":2}|} golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "incomplete-reset" mutated | Error e -> print_string e);
  [%expect {| incomplete-reset: true |}]

(* --- generation/lineage_id canonical-decimal enforcement (both decode and encode) ---

   {!Json.canonical_decimal} (mirrored, not solely implemented, by the browser-side decoder) accepts
   only digits, no sign, and no leading zero unless the whole string is exactly ["0"]. These cases
   prove the OCaml codec itself is the enforcement point, on both directions, for both fields --
   fixing the gap where [meta_jsont] previously mapped both with plain [Jsont.string]. *)

let%expect_test "decode_html_frame rejects a non-digit generation" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"generation":"1"|} ~by:{|"generation":"not-a-number"|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-generation-digits" mutated | Error e -> print_string e);
  [%expect {| bad-generation-digits: true |}]

let%expect_test "decode_html_frame rejects a negative generation" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"generation":"1"|} ~by:{|"generation":"-1"|} golden)
  in
  (match result with Ok mutated -> check_rejected "negative-generation" mutated | Error e -> print_string e);
  [%expect {| negative-generation: true |}]

let%expect_test "decode_html_frame rejects a leading-zero generation" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"generation":"1"|} ~by:{|"generation":"01"|} golden)
  in
  (match result with Ok mutated -> check_rejected "leading-zero-generation" mutated | Error e -> print_string e);
  [%expect {| leading-zero-generation: true |}]

let%expect_test "decode_html_frame rejects a non-digit lineage_id" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"lineage_id":"3"|} ~by:{|"lineage_id":"not-a-number"|} golden)
  in
  (match result with Ok mutated -> check_rejected "bad-lineage-digits" mutated | Error e -> print_string e);
  [%expect {| bad-lineage-digits: true |}]

let%expect_test "decode_html_frame rejects a negative lineage_id" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"lineage_id":"3"|} ~by:{|"lineage_id":"-1"|} golden)
  in
  (match result with Ok mutated -> check_rejected "negative-lineage" mutated | Error e -> print_string e);
  [%expect {| negative-lineage: true |}]

let%expect_test "decode_html_frame rejects a leading-zero lineage_id" =
  let result =
    let* golden = golden_html () in
    Ok (replace ~sub:{|"lineage_id":"3"|} ~by:{|"lineage_id":"03"|} golden)
  in
  (match result with Ok mutated -> check_rejected "leading-zero-lineage" mutated | Error e -> print_string e);
  [%expect {| leading-zero-lineage: true |}]

let check_encode_rejected name (envelope : Json.html_envelope) =
  Format.printf "%s: %a@." name Fmt.bool (Result.is_error (Json.encode_html_frame envelope))

let%expect_test "encode_html_frame rejects a hand-built envelope with a malformed generation" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    Ok { envelope with meta = { envelope.meta with generation = "not-a-number" } }
  in
  (match result with
  | Ok envelope -> check_encode_rejected "encode-bad-generation-digits" envelope
  | Error e -> print_string e);
  [%expect {| encode-bad-generation-digits: true |}]

let%expect_test "encode_html_frame rejects a hand-built envelope with a negative generation" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    Ok { envelope with meta = { envelope.meta with generation = "-1" } }
  in
  (match result with
  | Ok envelope -> check_encode_rejected "encode-negative-generation" envelope
  | Error e -> print_string e);
  [%expect {| encode-negative-generation: true |}]

let%expect_test "encode_html_frame rejects a hand-built envelope with a leading-zero generation" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    Ok { envelope with meta = { envelope.meta with generation = "01" } }
  in
  (match result with
  | Ok envelope -> check_encode_rejected "encode-leading-zero-generation" envelope
  | Error e -> print_string e);
  [%expect {| encode-leading-zero-generation: true |}]

let%expect_test "encode_html_frame rejects a hand-built envelope with a malformed lineage_id" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    Ok { envelope with meta = { envelope.meta with lineage_id = "not-a-number" } }
  in
  (match result with
  | Ok envelope -> check_encode_rejected "encode-bad-lineage-digits" envelope
  | Error e -> print_string e);
  [%expect {| encode-bad-lineage-digits: true |}]

let%expect_test "encode_html_frame rejects a hand-built envelope with a negative lineage_id" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    Ok { envelope with meta = { envelope.meta with lineage_id = "-1" } }
  in
  (match result with
  | Ok envelope -> check_encode_rejected "encode-negative-lineage" envelope
  | Error e -> print_string e);
  [%expect {| encode-negative-lineage: true |}]

let%expect_test "encode_html_frame rejects a hand-built envelope with a leading-zero lineage_id" =
  let result =
    let* frame = build () in
    let envelope = Json.html_envelope_of frame in
    Ok { envelope with meta = { envelope.meta with lineage_id = "03" } }
  in
  (match result with
  | Ok envelope -> check_encode_rejected "encode-leading-zero-lineage" envelope
  | Error e -> print_string e);
  [%expect {| encode-leading-zero-lineage: true |}]

let%expect_test "decode_canvas_frame rejects a tiny payload declaring an enormous rows without allocating" =
  (* Same class of bug as the HTML case above: a decoder that groups ops into a scratch table sized directly from
     the declared geometry (e.g. [Array.make rows []]) would raise [Invalid_argument] or exhaust memory here. *)
  let result =
    let* golden = golden_canvas () in
    Ok
      (replace ~sub:{|"geometry":{"columns":2,"rows":1}|} ~by:{|"geometry":{"columns":2,"rows":4611686018427387903}|}
         golden)
  in
  (match result with Ok mutated -> check_rejected_canvas "huge-rows" mutated | Error e -> print_string e);
  [%expect {| huge-rows: true |}]
