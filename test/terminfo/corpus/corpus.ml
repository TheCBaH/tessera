(* Named byte/text corpus for adversarial Terminfo source and compiled input, retained as a
   deterministic regression seam for test/fuzz: crashes the fuzz targets find land here, reduced to
   a minimal reproduction, so a fix never regresses silently. *)
module Terminfo = Tessera_terminfo
open Tessera_test_support.Support

type case = { name : string; category : string; resource : Terminfo.Terminfo.resource }

let cases =
  [
    (* test/fuzz/terminfo_fuzz.ml found this exact class: [first_unescaped] jumped two bytes past a
       backslash without checking a following byte existed, overrunning the string on a lone
       trailing backslash. This is the minimal reproduction: a field consisting of a single
       backslash. *)
    {
      name = "source-field-trailing-backslash";
      category = "field scanning";
      resource = Terminfo.Terminfo.Source "demo,\\";
    };
    {
      name = "source-boolean-field-trailing-backslash";
      category = "field scanning";
      resource = Terminfo.Terminfo.Source "demo,x\\";
    };
    {
      name = "source-number-field-trailing-backslash";
      category = "field scanning";
      resource = Terminfo.Terminfo.Source "demo,x#1\\";
    };
    {
      name = "source-string-value-trailing-backslash";
      category = "capability decoding";
      resource = Terminfo.Terminfo.Source "demo,x=a\\";
    };
    {
      name = "source-field-escaped-backslash-pair";
      category = "field scanning";
      resource = Terminfo.Terminfo.Source "demo,\\\\";
    };
    { name = "compiled-empty-bytes"; category = "compiled framing"; resource = Terminfo.Terminfo.Compiled Bytes.empty };
  ]

let%expect_test "terminfo corpus: adversarial source/compiled cases parse deterministically" =
  (match policy () with
  | Error error -> Format.print_string error
  | Ok policy ->
      List.iter
        (fun { name; category; resource } ->
          let result = with_error Terminfo.Terminfo.E.Error.pp_kind (Terminfo.Terminfo.parse policy resource) in
          Format.printf "[%s] %s: %a@." category name (pp_result Terminfo.Description.pp) result)
        cases);
  [%expect
    {|
    [field scanning] source-field-trailing-backslash: description(capabilities=[])
    [field scanning] source-boolean-field-trailing-backslash: description(capabilities=[])
    [field scanning] source-number-field-trailing-backslash: source syntax: line 1, column 6: invalid number
    [capability decoding] source-string-value-trailing-backslash: source syntax: line 1, column 6: truncated escape
    [field scanning] source-field-escaped-backslash-pair: description(capabilities=[])
    [compiled framing] compiled-empty-bytes: compiled format: truncated compiled entry |}]
