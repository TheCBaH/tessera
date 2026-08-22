module Terminfo = Tessera_terminfo
module Fixtures = Tessera_test_fixtures.Fixtures
open Tessera_test_support.Support

let%expect_test "public facade parses baseline compiled terminfo" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Compiled (Fixtures.compiled_terminfo ())))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {|
    description(capabilities=[clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"]) |}]

let%expect_test "public facade parses extended compiled terminfo data" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Compiled (Fixtures.extended_compiled_terminfo ())))
  in
  let pp_description ppf description =
    Format.fprintf ppf "description=%a@.names=[%a]@.extensions=[%a]" Terminfo.Description.pp description
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf name -> Format.fprintf ppf "%S" name))
      (Terminfo.Description.names description)
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf (name, value) -> Format.fprintf ppf "%s=%a" name Terminfo.Description.pp_extension_value value))
      (Terminfo.Description.extensions description)
  in
  Format.printf "%a@." (pp_result pp_description) result;
  [%expect
    {|
    description=description(capabilities=[clear-screen="\027[2J"])
    names=["demo"]
    extensions=[xb=boolean; xn=number(42); xs=string("value")] |}]

let%expect_test "public facade validates every compiled string offset" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp_kind
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Compiled (Fixtures.malformed_compiled_terminfo ())))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| compiled format: invalid compiled string offset |}]

let%expect_test "public facade validates every extended capability name offset" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp_kind
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Compiled (Fixtures.malformed_extended_compiled_terminfo ())))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| compiled format: missing extended capability name |}]
