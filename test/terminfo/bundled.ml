module Terminfo = Tessera_terminfo

let%expect_test "the bundled xterm-256color description parses with the expected name and capabilities" =
  Format.printf "name=%s identity=%a@." Terminfo.Bundled.name
    (Format.pp_print_option Format.pp_print_string)
    (Terminfo.Description.identity Terminfo.Bundled.description);
  Format.printf "%a@." Terminfo.Description.pp Terminfo.Bundled.description;
  [%expect
    {|
    name=xterm-256color identity=xterm-256color
    description(capabilities=[clear-screen="\027[H\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"; cursor-down="\n"; cursor-left="\b"; cursor-right="\027[C"; cursor-up="\027[A"; erase-char="\027[%p1%dX"; erase-line="\027[K"]) |}]

let%expect_test "a candidate description with identical overlapping capabilities is compatible" =
  let candidate =
    Terminfo.Description.make_with_source
      ~capabilities:(Terminfo.Description.capabilities Terminfo.Bundled.description)
      ~extensions:[] ~names:[ "xterm-256color" ] ~uses:[]
  in
  Format.printf "%b@." (Terminfo.Bundled.is_compatible candidate);
  [%expect {| true |}]

let%expect_test "a candidate description omitting some capabilities is still compatible" =
  let candidate =
    Terminfo.Description.make
      ~capabilities:
        (Result.get_ok
           (Terminfo.Description.Capability_map.of_list [ (Terminfo.Description.Clear_screen, "\027[H\027[2J") ]))
  in
  Format.printf "%b@." (Terminfo.Bundled.is_compatible candidate);
  [%expect {| true |}]

let%expect_test "a candidate description with a conflicting capability value is not compatible" =
  let candidate =
    Terminfo.Description.make
      ~capabilities:
        (Result.get_ok
           (Terminfo.Description.Capability_map.of_list [ (Terminfo.Description.Clear_screen, "\027[H\027[J") ]))
  in
  Format.printf "%b@." (Terminfo.Bundled.is_compatible candidate);
  [%expect {| false |}]
