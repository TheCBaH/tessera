(* Named byte corpus for malformed/framing decoder inputs. Additive breadth alongside the
   component suites in test/decoder: every case here is decoded through
   the same [feed]/[finish] path and its final diagnostic/update projection is printed, so this
   is the retained-corpus seam the later fuzz milestone will extend. *)
module Model = Tessera_model
module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support

let decode_to_end policy text =
  let* slice = slice text in
  let* fed = with_error_kind Decoder.pp_error (Decoder.feed policy Decoder.initial slice) in
  let* finished = with_error_kind Decoder.pp_error (Decoder.finish policy fed.continuation) in
  Ok (Model.Effect.Item_sequence.append fed.items finished.items)

type case = { name : string; category : string; input : string }

let cases =
  [
    {
      name = "csi-parameter-count-exceeds-policy";
      category = "malformed CSI";
      input = "\027[" ^ String.concat ";" (List.init 17 (fun index -> string_of_int (index + 1))) ^ "A";
    };
    { name = "csi-parameter-overflow"; category = "malformed CSI"; input = "\027[999999999999999999999999A" };
    { name = "csi-unterminated-intermediate"; category = "malformed CSI"; input = "\027[1;2" };
    {
      name = "osc-oversized-body";
      category = "oversized control string";
      input = "\027]" ^ String.make 2000 'a' ^ "\007";
    };
    { name = "dcs-unsupported"; category = "unsupported control string"; input = "\027Punsupported\027\\" };
    { name = "apc-unsupported"; category = "unsupported control string"; input = "\027_unsupported\027\\" };
    { name = "osc-st-split-across-feeds"; category = "fragmented terminator"; input = "\027]0;a\027\\" };
    { name = "sos-st-split-across-feeds"; category = "fragmented terminator"; input = "\027Xa\027\\" };
    { name = "c1-osc-title"; category = "C1 framing"; input = "\x9d0;title\x9c" };
    { name = "c1-dcs-unsupported"; category = "C1 framing"; input = "\x90unsupported\x9c" };
    { name = "can-cancels-csi"; category = "cancellation"; input = "\027[1;2\024A" };
    { name = "sub-cancels-osc"; category = "cancellation"; input = "\027]0;ignored\026A" };
    { name = "invalid-utf8-continuation"; category = "invalid UTF-8"; input = "\xc3\x28" };
    { name = "invalid-utf8-lone-continuation"; category = "invalid UTF-8"; input = "\x80" };
    { name = "osc-unterminated-eof"; category = "unterminated EOF"; input = "\027]0;never-closed" };
    { name = "dcs-unterminated-eof"; category = "unterminated EOF"; input = "\027Pnever-closed" };
  ]

let%expect_test "decoder corpus: malformed and framing cases decode deterministically" =
  (match policy () with
  | Error error -> Format.print_string error
  | Ok policy ->
      List.iter
        (fun { name; category; input } ->
          let result = decode_to_end policy input in
          Format.printf "[%s] %s: %a@." category name (pp_result Model.Effect.Item_sequence.pp) result)
        cases);
  [%expect
    {|
    [malformed CSI] csi-parameter-count-exceeds-policy: [observation(diagnostic(malformed-csi(offset=0; reason="parameter count exceeds policy")))]
    [malformed CSI] csi-parameter-overflow: [observation(diagnostic(unsupported-sequence(family="CSI"; offset=0)))]
    [malformed CSI] csi-unterminated-intermediate: [observation(diagnostic(malformed-csi(offset=0; reason="unterminated sequence")))]
    [oversized control string] osc-oversized-body: [observation(diagnostic(control-string-too-long(kind="OSC"; offset=0)))]
    [unsupported control string] dcs-unsupported: [observation(diagnostic(unsupported-sequence(family="DCS"; offset=0)))]
    [unsupported control string] apc-unsupported: [observation(diagnostic(unsupported-sequence(family="APC"; offset=0)))]
    [fragmented terminator] osc-st-split-across-feeds: [update(set-title("a"))]
    [fragmented terminator] sos-st-split-across-feeds: [observation(diagnostic(unsupported-sequence(family="SOS"; offset=0)))]
    [C1 framing] c1-osc-title: [update(set-title("title"))]
    [C1 framing] c1-dcs-unsupported: [observation(diagnostic(unsupported-sequence(family="DCS"; offset=0)))]
    [cancellation] can-cancels-csi: [update(print([<U+0041>]))]
    [cancellation] sub-cancels-osc: [update(print([<U+0041>]))]
    [invalid UTF-8] invalid-utf8-continuation: [observation(diagnostic(invalid-utf8(offset=0))); update(print([<U+FFFD>])); update(print([<U+0028>]))]
    [invalid UTF-8] invalid-utf8-lone-continuation: [observation(diagnostic(invalid-utf8(offset=0))); update(print([<U+FFFD>]))]
    [unterminated EOF] osc-unterminated-eof: [observation(diagnostic(unsupported-sequence(family="OSC"; offset=0)))]
    [unterminated EOF] dcs-unterminated-eof: [observation(diagnostic(unsupported-sequence(family="DCS"; offset=0)))] |}]
