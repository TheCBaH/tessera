module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support
open Decoder_support

let%expect_test "decoder diagnostics retain stream offsets and obey their budget" =
  let result =
    let* policy = policy ~max_diagnostics:2 () in
    decode policy Decoder.initial "\007\255\027[99z"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {|
    {continuation=decoder-continuation(offset=7; diagnostics=0; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="BEL"; offset=0))); observation(diagnostic(invalid-utf8(offset=1))); update(print([<U+FFFD>]))]} |}]

let%expect_test "decoder maps C0, ESC, and CSI editing operations" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial
      "\b\t\n\
       \011\012\r\0277\0278\027D\027M\027E\027H\027c\027[2A\027[2B\027[2C\027[2D\027[2G\027[2d\027[2J\027[1K\027[2X\027[2P\027[2@\027[2L\027[2M\027[2S\027[2T"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=80; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(backspace); update(horizontal-tab); update(line-feed); update(line-feed); update(line-feed); update(carriage-return); update(save-cursor); update(restore-cursor); update(scroll-up(1)); update(scroll-down(1)); update(carriage-return); update(line-feed); update(set-tab); update(reset); update(move-cursor(up(2))); update(move-cursor(down(2))); update(move-cursor(forward(2))); update(move-cursor(back(2))); update(move-cursor(column(1))); update(move-cursor(row(1))); update(erase(display(clear-all))); update(erase(line(clear-left))); update(edit(erase-chars(2))); update(edit(delete-chars(2))); update(edit(insert-chars(2))); update(edit(insert-lines(2))); update(edit(delete-lines(2))); update(scroll-up(2)); update(scroll-down(2))]} |}]

let%expect_test "decoder maps C1 single controls" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\x84\x85\x88\x8d"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=4; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(scroll-up(1)); update(carriage-return); update(line-feed); update(set-tab); update(scroll-down(1))]} |}]

let%expect_test "decoder cancellation discards incomplete OSC and CSI" =
  let decoded =
    let* policy = policy () in
    decode policy Decoder.initial "\027]2;ignored\024A\027[12\026B"
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
    decoded={continuation=decoder-continuation(offset=19; diagnostics=16; ground; utf8=pending(<U+0042>); bytes=complete); items=[update(print([<U+0041>]))]}
    finished={continuation=decoder-continuation(offset=19; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(print([<U+0042>]))]} |}]
