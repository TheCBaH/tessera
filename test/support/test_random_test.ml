module Test_random = Tessera_test_support.Test_random

let%expect_test "a seeded state yields a stable sequence" =
  let state = Test_random.State.make [| 0x54455341 |] in
  List.init 8 (fun _ -> Test_random.State.int state 8) |> List.iter (Format.printf "%d ");
  Format.printf "\n";
  [%expect {| 6 7 4 5 2 3 0 1 |}]
