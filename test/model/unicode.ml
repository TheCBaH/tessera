module Model = Tessera_model
open Tessera_test_support.Support

let%expect_test "Unicode graphemes remain stable across boundaries" =
  let result =
    let* policy = policy () in
    let feed continuation scalar =
      with_error_kind Model.Unicode.pp_error (Model.Unicode.feed policy continuation (Uchar.of_int scalar))
    in
    let* continuation, first = feed Model.Unicode.initial 0x61 in
    let* continuation, second = feed continuation 0x301 in
    let* continuation, completed = feed continuation 0x62 in
    let* final = with_error_kind Model.Unicode.pp_error (Model.Unicode.finish policy continuation) in
    Ok (first, second, completed, final)
  in
  let pp_graphemes ppf (first, second, completed, final) =
    Format.fprintf ppf "first=%a@.second=%a@.completed=%a@.final=%a@.wide=%a@.combining=%a@."
      Model.Unicode.Grapheme_sequence.pp first Model.Unicode.Grapheme_sequence.pp second
      Model.Unicode.Grapheme_sequence.pp completed Model.Unicode.Grapheme_sequence.pp final Model.Unicode.pp_width
      (Model.Unicode.width (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x4e00)))
      Model.Unicode.pp_width
      (Model.Unicode.width (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x301)))
  in
  Format.printf "%a" (pp_result pp_graphemes) result;
  [%expect
    {|
    first=[]
    second=[]
    completed=[<U+0061U+0301>]
    final=[<U+0062>]
    wide=two
    combining=zero |}]

let%expect_test "grapheme width distinguishes Emoji from Emoji_Presentation" =
  (* Regression: ASCII digits, [#], and [*] carry Unicode's raw [Emoji] property (they are the
     keycap-eligible base of sequences like "1\xEF\xB8\x8F\xE2\x83\xA3"), but render as ordinary
     narrow text on their own -- [Emoji_Presentation] is the property that reflects default rendered
     width. Node-pty.md's real-program tests caught this: every digit a real terminal program printed
     came out double-width and interleaved with a wide-continuation cell. *)
  let width codepoint = Model.Unicode.width (Model.Unicode.grapheme_of_scalar (Uchar.of_int codepoint)) in
  let pp_widths ppf () =
    Format.fprintf ppf "digit=%a hash=%a star=%a heart=%a grinning_face=%a@." Model.Unicode.pp_width (width 0x30)
      Model.Unicode.pp_width (width 0x23) Model.Unicode.pp_width (width 0x2a) Model.Unicode.pp_width (width 0x2764)
      Model.Unicode.pp_width (width 0x1f600)
  in
  Format.printf "%a" pp_widths ();
  [%expect {| digit=one hash=one star=one heart=one grinning_face=two |}]
