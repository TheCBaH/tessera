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
