module Terminfo = Tessera_terminfo
open Tessera_test_support.Support

let%expect_test "public facade parses terminfo source escapes" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo|portable,clear=\\E[2J,cup=\\E[%i%p1%d;%p2%dH,"))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| description(capabilities=[clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"]) |}]

let%expect_test "public facade preserves escaped terminfo field delimiters" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,tsl=title\\,value,"))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| description(capabilities=[set-title="title,value"]) |}]

let%expect_test "public facade retains source names and extension fields" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.parse policy
         (Terminfo.Terminfo.Source
            "# comment, ignored\ndemo|portable,am,cols#80,clear=\\E[2J,clear@,xfoo=title\\,value,use=base,"))
  in
  let pp_description ppf description =
    let pp_name ppf name = Format.fprintf ppf "%S" name in
    let pp_extension ppf (name, value) =
      Format.fprintf ppf "%s=%a" name Terminfo.Description.pp_extension_value value
    in
    Format.fprintf ppf "names=[%a]@.extensions=[%a]@.uses=[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_name)
      (Terminfo.Description.names description)
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_extension)
      (Terminfo.Description.extensions description)
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_name)
      (Terminfo.Description.uses description)
  in
  Format.printf "%a@." (pp_result pp_description) result;
  [%expect
    {|
    names=["demo"; "portable"]
    extensions=[am=boolean; cols=number(80); clear=cancelled; xfoo=string("title,value")]
    uses=["base"] |}]

let%expect_test "public facade reports source escape locations" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp_kind
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,\n  clear=\\q,"))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| source syntax: line 2, column 3: invalid escape |}]

let%expect_test "public facade resolves terminfo use dependencies" =
  let result =
    let* policy = policy () in
    let* base =
      with_error Terminfo.Terminfo.E.Error.pp
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "base,clear=\\E[2J,"))
    in
    let* child =
      with_error Terminfo.Terminfo.E.Error.pp
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "child,use=base,cup=\\E[%i%p1%d;%p2%dH,"))
    in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.resolve_use child ~lookup:(fun name -> if name = "base" then Some base else None))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| description(capabilities=[clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"]) |}]

let%expect_test "public facade preserves source extensions through terminfo use resolution" =
  let result =
    let* policy = policy () in
    let* base =
      with_error Terminfo.Terminfo.E.Error.pp (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "base,am,"))
    in
    let* child =
      with_error Terminfo.Terminfo.E.Error.pp
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "child,use=base,"))
    in
    with_error Terminfo.Terminfo.E.Error.pp
      (Terminfo.Terminfo.resolve_use child ~lookup:(fun name -> if name = "base" then Some base else None))
  in
  let pp_description ppf description =
    Format.fprintf ppf "names=[%a]@.extensions=[%a]"
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
  [%expect {|
    names=["child"]
    extensions=[am=boolean] |}]

let%expect_test "public facade reports unresolved terminfo use" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "child,use=missing,"))
    in
    with_error Terminfo.Terminfo.E.Error.pp_kind (Terminfo.Terminfo.resolve_use description ~lookup:(fun _ -> None))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {| source syntax: unknown use="missing" |}]

let%expect_test "public facade rejects malformed terminfo escapes" =
  let result =
    let* policy = policy () in
    with_error Terminfo.Terminfo.E.Error.pp_kind
      (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,clear=\\q,"))
  in
  Format.printf "%a@." (pp_result Terminfo.Description.pp) result;
  [%expect {|
    source syntax: line 1, column 6: invalid escape |}]
