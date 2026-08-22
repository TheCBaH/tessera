module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support
open Decoder_support

let%expect_test "decoder maps fragmented ESC CSI sequences" =
  let result =
    let* policy = policy () in
    let* first = decode policy Decoder.initial "\027[2;" in
    decode policy first.continuation "3H\027[2J\027[1;3;24m"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=19; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(move-cursor(position((2,1)))); update(erase(display(clear-all))); update(set-style({ background=keep; bold=true; faint=keep; foreground=keep; invisible=keep; inverse=keep; italic=true; strikethrough=keep; underline=false }))]} |}]

let%expect_test "decoder maps CSI line-relative cursor moves" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[2E\027[F"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=7; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(move-cursor(next-line(2))); update(move-cursor(previous-line(1)))]} |}]

let%expect_test "decoder maps DEC private modes" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[?6;7;25l"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=10; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-mode({auto_wrap=false; cursor_visible=false; insert=keep; origin=false}))]} |}]

let%expect_test "decoder maps indexed and RGB SGR colours" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[31;48;5;42;38;2;1;2;3m"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=24; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-style({ background=indexed(42); bold=keep; faint=keep; foreground=rgb(1,2,3); invisible=keep; inverse=keep; italic=keep; strikethrough=keep; underline=keep }))]} |}]

let%expect_test "decoder discards CSI sequences above the parameter limit" =
  let result =
    let* policy = policy ~max_csi_params:2 () in
    decode policy Decoder.initial "\027[1;2;3A"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=8; diagnostics=15; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(malformed-csi(offset=0; reason="parameter count exceeds policy")))]} |}]

let%expect_test "decoder rejects overflowing CSI parameters" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[999999999999999999999999A"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=27; diagnostics=15; ground; utf8=empty; bytes=complete); items=[observation(diagnostic(unsupported-sequence(family="CSI"; offset=0)))]} |}]

let%expect_test "decoder switches the alternate screen through DEC modes" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[?1049h\027[?1049l"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=16; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(alternate-screen(enter-1049)); update(alternate-screen(leave-1049))]} |}]

let%expect_test "decoder maps CSI cursor save and restore" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[s\027[u"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=6; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(save-cursor); update(restore-cursor)]} |}]

let%expect_test "decoder maps standard insert mode" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[4h\027[4l"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=8; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-mode({auto_wrap=keep; cursor_visible=keep; insert=true; origin=keep})); update(set-mode({auto_wrap=keep; cursor_visible=keep; insert=false; origin=keep}))]} |}]

let%expect_test "decoder maps explicit scrolling margins" =
  let result =
    let* policy = policy () in
    decode policy Decoder.initial "\027[2;3r"
  in
  Format.printf "%a@." (pp_result Decoder.pp_decoded) result;
  [%expect
    {| {continuation=decoder-continuation(offset=6; diagnostics=16; ground; utf8=empty; bytes=complete); items=[update(set-margins({top=1; bottom=2}))]} |}]
