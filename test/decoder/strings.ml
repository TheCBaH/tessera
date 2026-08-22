module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support
open Decoder_support

let%expect_test "oversized strings discard through their terminator" =
  let first =
    let* policy = policy ~max_control_bytes:2 () in
    decode policy Decoder.initial "\027]abc"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) first;
  let second =
    let* policy = policy ~max_control_bytes:2 () in
    let* first = first in
    decode policy first.continuation "ignored\007X"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) second;
  let final =
    let* policy = policy ~max_control_bytes:2 () in
    let* second = second in
    finish policy second.continuation
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) final;
  [%expect
    {|
    {continuation=decoder-continuation(offset=5; diagnostics=15; discard-string; utf8=empty; bytes=complete); items=[observation(diagnostic(control-string-too-long(kind="OSC"; offset=0)))]}
    {continuation=decoder-continuation(offset=14; diagnostics=15; ground; utf8=pending(<U+0058>); bytes=complete); items=[]}
    {continuation=decoder-continuation(offset=14; diagnostics=15; ground; utf8=empty; bytes=complete); items=[update(print([<U+0058>]))]} |}]

let%expect_test "decoder frames OSC titles" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027]2;tessera\007"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=12; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-title("tessera"))]} |}]

let%expect_test "decoder accepts fragmented OSC string terminators" =
  let first =
    let* policy = policy () in
    decode policy Decoder.initial "\027]0;tessera\027"
  in
  let second =
    let* policy = policy () in
    let* first = first in
    decode policy first.continuation "\\"
  in
  Format.printf "first=%a@.second=%a@." (pp_result Decoder.pp_decoded) first (pp_result Decoder.pp_decoded) second;
  [%expect
    {|
    first={continuation=decoder-continuation(offset=12; diagnostics=16; osc; utf8=empty; bytes=complete); items=[]}
    second={continuation=decoder-continuation(offset=13; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-title("tessera"))]} |}]

let%expect_test "decoder accepts C1 control string framing" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\x9d2;tessera\x9c\x90ignored\x9c"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=20; diagnostics=15; ground; utf8=empty; bytes=complete); items=[update(set-title("tessera")); observation(diagnostic(unsupported-sequence(family="DCS"; offset=11)))]} |}]

let%expect_test "decoder frames fragmented SOS strings" =
  let first =
    let* policy = policy () in
    decode policy Decoder.initial "\x98ignored\027"
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
  Format.printf "first=%a@.second=%a@.finished=%a@." (pp_result Decoder.pp_decoded) first (pp_result Decoder.pp_decoded)
    second (pp_result Decoder.pp_decoded) finished;
  [%expect
    {|
    first={continuation=decoder-continuation(offset=9; diagnostics=15; discard-string; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="SOS"; offset=0)))]}
    second={continuation=decoder-continuation(offset=11; diagnostics=15; ground; utf8=pending(<U+0041>); bytes=complete); items=[]}
    finished={continuation=decoder-continuation(offset=11; diagnostics=15; ground; utf8=empty; bytes=complete); items=[update(print([<U+0041>]))]} |}]

let%expect_test "decoder reports unterminated control strings only at EOF" =
  let decoded =
    let* policy = policy () in
    decode policy Decoder.initial "\027]2;unterminated"
  in
  let finished =
    let* policy = policy () in
    let* decoded = decoded in
    finish policy decoded.continuation
  in
  Format.printf "decoded=%a@.finished=%a@." (pp_result Decoder.pp_decoded) decoded (pp_result Decoder.pp_decoded)
    finished;
  [%expect
    {|
    decoded={continuation=decoder-continuation(offset=16; diagnostics=16; osc; utf8=empty; bytes=complete); items=[]}
    finished={continuation=decoder-continuation(offset=16; diagnostics=15; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="OSC"; offset=0)))]} |}]

let%expect_test "decoder frames unsupported control strings" =
  let decoded =
    let* policy = policy () in
    decode policy Decoder.initial "\027Pdcs\027\\\027_apc\027\\\027^pm\027\\A"
  in
  let finished =
    let* policy = policy () in
    let* decoded = decoded in
    with_error_kind Decoder.pp_error (Decoder.finish policy decoded.continuation)
  in
  Format.printf "decoded=%a@.finished=%a@." (pp_result Decoder.pp_decoded) decoded (pp_result Decoder.pp_decoded)
    finished;
  [%expect
    {|
    decoded={continuation=decoder-continuation(offset=21; diagnostics=13; ground; utf8=pending(<U+0041>); bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="DCS"; offset=0))); observation(diagnostic(unsupported-sequence(family="APC"; offset=7))); observation(diagnostic(unsupported-sequence(family="PM"; offset=14)))]}
    finished={continuation=decoder-continuation(offset=21; diagnostics=13; ground; utf8=empty; bytes=complete); items=[update(print([<U+0041>]))]} |}]
