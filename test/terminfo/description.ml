module Terminfo = Tessera_terminfo
open Tessera_test_support.Support

let%expect_test "public facade canonicalizes terminal capabilities" =
  let result =
    let* earlier =
      with_error Terminfo.Description.E.Error.pp
        (Terminfo.Description.Capability_map.of_list [ (Terminfo.Description.Clear_screen, "\027[2J") ])
    in
    let* later =
      with_error Terminfo.Description.E.Error.pp
        (Terminfo.Description.Capability_map.of_list [ (Terminfo.Description.Cursor_address, "\027[%i%p1%d;%p2%dH") ])
    in
    with_error Terminfo.Description.E.Error.pp (Terminfo.Description.Capability_map.merge ~earlier ~later)
  in
  Format.printf "%a@." (pp_result Terminfo.Description.Capability_map.pp) result;
  [%expect {| [clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"] |}]
