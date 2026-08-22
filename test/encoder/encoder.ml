module Foundation = Tessera_foundation
module Model = Tessera_model
module Terminfo = Tessera_terminfo
open Tessera_test_support.Support

let%expect_test "public facade encodes capability-backed updates" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy
           (Terminfo.Terminfo.Source "demo,clear=\\E[2J,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let* count = uint 2 and* column = uint 3 and* row = uint 1 in
    let position =
      Foundation.Types.coord ~column:(Foundation.Types.Column.of_uint column) ~row:(Foundation.Types.Row.of_uint row)
    in
    let batch =
      Model.Update.Batch.append
        (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Position position)))
        (Model.Update.Batch.append
           (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Erase_chars count)))
           (Model.Update.Batch.singleton Model.Update.Reset))
    in
    with_error Terminfo.Encoder.E.Error.pp_kind (Terminfo.Encoder.encode description policy batch)
  in
  Format.printf "%a@." (pp_result Terminfo.Encoder.pp_byte_chunks) result;
  [%expect {| ["\027[2;4H"; "\027[2X"; "\027[2J"] |}]

let%expect_test "public facade encodes every controlled release-one update" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy
           (Terminfo.Terminfo.Source "demo,clear=C,el=E,ech=X%p1%d,cup=P%p1%d\\,%p2%d,cud1=D,cub1=L,cuf1=R,cuu1=U,"))
    in
    let* count = uint 2 and* column = uint 3 and* row = uint 1 in
    let position =
      Foundation.Types.coord ~column:(Foundation.Types.Column.of_uint column) ~row:(Foundation.Types.Row.of_uint row)
    in
    let graphemes = Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)) in
    let batch =
      batch_of_updates
        [
          Model.Update.Reset;
          Model.Update.Erase (Model.Update.Display `Clear_all);
          Model.Update.Erase (Model.Update.Line `Clear_right);
          Model.Update.Edit (Model.Update.Erase_chars count);
          Model.Update.Move_cursor (Model.Update.Position position);
          Model.Update.Move_cursor (Model.Update.Up count);
          Model.Update.Move_cursor (Model.Update.Down count);
          Model.Update.Move_cursor (Model.Update.Back count);
          Model.Update.Move_cursor (Model.Update.Forward count);
          Model.Update.Print graphemes;
        ]
    in
    with_error Terminfo.Encoder.E.Error.pp_kind (Terminfo.Encoder.encode description policy batch)
  in
  Format.printf "%a@." (pp_result Terminfo.Encoder.pp_byte_chunks) result;
  [%expect {| ["C"; "C"; "E"; "X2"; "P1,3"; "U"; "U"; "D"; "D"; "L"; "L"; "R"; "R"; "A"] |}]

let%expect_test "public facade rejects an empty repeated capability" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,cuu1=,"))
    in
    let* count = uint 1 in
    with_error Terminfo.Encoder.E.Error.pp_kind
      (Terminfo.Encoder.encode description policy
         (Model.Update.Batch.singleton (Model.Update.Move_cursor (Model.Update.Up count))))
  in
  Format.printf "%a@." (pp_result Terminfo.Encoder.pp_byte_chunks) result;
  [%expect {| unexpressible update: move-cursor(up(1)) |}]

let%expect_test "public facade rejects unsupported terminfo capability operations" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,ech=\\E[%{1}%dX,"))
    in
    let* count = uint 1 in
    with_error Terminfo.Encoder.E.Error.pp_kind
      (Terminfo.Encoder.encode description policy
         (Model.Update.Batch.singleton (Model.Update.Edit (Model.Update.Erase_chars count))))
  in
  Format.printf "%a@." (pp_result Terminfo.Encoder.pp_byte_chunks) result;
  [%expect {| unexpressible update: edit(erase-chars(1)) |}]

let%expect_test "public facade encodes documented literal percent operations" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,clear=\\E[%%2J,"))
    in
    with_error Terminfo.Encoder.E.Error.pp_kind
      (Terminfo.Encoder.encode description policy (Model.Update.Batch.singleton Model.Update.Reset))
  in
  Format.printf "%a@." (pp_result Terminfo.Encoder.pp_byte_chunks) result;
  [%expect {| ["\027[%2J"] |}]

let%expect_test "public facade reports unexpressible updates" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Terminfo.Terminfo.E.Error.pp_kind
        (Terminfo.Terminfo.parse policy (Terminfo.Terminfo.Source "demo,clear=\\E[2J,"))
    in
    with_error Terminfo.Encoder.E.Error.pp_kind
      (Terminfo.Encoder.encode description policy (Model.Update.Batch.singleton Model.Update.Horizontal_tab))
  in
  Format.printf "%a@." (pp_result Terminfo.Encoder.pp_byte_chunks) result;
  [%expect {| unexpressible update: horizontal-tab |}]
