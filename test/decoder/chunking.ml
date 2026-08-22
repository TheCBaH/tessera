module Model = Tessera_model
module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support
open Decoder_support

let%expect_test "decoder chunking preserves mixed text and control output" =
  let result =
    let* policy = policy () in
    let text = "A\xc3\xa9\027[2;3H\027]2;tessera\007" in
    let* whole = decode policy Decoder.initial text in
    let* chunked = decode_chunks policy [ "A\xc3"; "\xa9\027[2"; ";3H\027]2"; ";tessera\007" ] in
    Ok ((whole.items, whole.continuation), chunked)
  in
  let pp_output = Fmt.pair Model.Effect.Item_sequence.pp Decoder.pp in
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

let%expect_test "decoder preserves fragmented UTF-8 through EOF" =
  let partial =
    let* policy = policy () in
    decode policy Decoder.initial "\xc3"
  in
  let complete =
    let* policy = policy () in
    let* partial = partial in
    decode policy partial.continuation "\xa9"
  in
  let final =
    let* complete = complete in
    let* policy = policy () in
    with_error_kind Decoder.pp_error (Decoder.finish policy complete.continuation)
  in
  Format.printf "partial=%a@.complete=%a@.final=%a@." (pp_result Decoder.pp_decoded) partial
    (pp_result Decoder.pp_decoded) complete (pp_result Decoder.pp_decoded) final;
  [%expect
    {|
    partial={continuation=decoder-continuation(offset=1; diagnostics=16; ground; utf8=empty; bytes=partial); items=[]}
    complete={continuation=decoder-continuation(offset=2; diagnostics=16; ground; utf8=pending(<U+00E9>); bytes=complete); items=[]}
    final={continuation=decoder-continuation(offset=2; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(print([<U+00E9>]))]} |}]
