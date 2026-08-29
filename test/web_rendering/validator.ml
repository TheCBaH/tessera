module Foundation = Tessera_foundation
module Model = Tessera_model
module Web = Tessera_web_rendering.Web_frame
open Tessera_test_support.Support

let uint_exn n = match Foundation.UInt.of_int n with Ok u -> u | Error _ -> assert false
let column n = Foundation.Types.Column.of_uint (uint_exn n)
let row n = Foundation.Types.Row.of_uint (uint_exn n)
let style = Model.Style.default
let size_exn columns rows = match size columns rows with Ok s -> s | Error e -> failwith e

let presentation size =
  {
    Web.active = Foundation.Types.Primary;
    cursor_position = Foundation.Types.coord ~column:(column 0) ~row:(row 0);
    cursor_pending_wrap = false;
    cursor_style = style;
    cursor_visible = true;
    title = None;
    size;
    generation = Foundation.Generation.zero;
    lineage_id = Foundation.Lineage_id.of_uint (uint_exn 1);
  }

let background start stop = { Web.start = column start; stop = column stop; style }
let glyph start width text = { Web.start = column start; width; text; style }

let check name frame =
  let result = with_error_kind Web.pp_error (Web.validate frame) in
  Format.printf "%s: %a@." name (pp_result (fun ppf () -> Format.pp_print_string ppf "valid")) result

let%expect_test "validate rejects a row index outside the frame's size" =
  let size = size_exn 3 2 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 2; background = [ background 0 3 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "row-out-of-range" frame;
  [%expect {| row-out-of-range: row-out-of-range(row=2) |}]

let%expect_test "validate rejects two rows sharing the same index" =
  let size = size_exn 3 2 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows =
        [
          { Web.index = row 0; background = [ background 0 3 ]; glyphs = [] };
          { Web.index = row 0; background = [ background 0 3 ]; glyphs = [] };
        ];
      presentation = presentation size;
    }
  in
  check "duplicate-row" frame;
  [%expect {| duplicate-row: duplicate-row(row=0) |}]

let%expect_test "validate rejects a Reset frame missing a row" =
  let size = size_exn 3 2 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 0; background = [ background 0 3 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "incomplete-reset" frame;
  [%expect {| incomplete-reset: incomplete-reset(missing-row=1) |}]

let%expect_test "validate accepts a Delta frame with only some rows present" =
  let size = size_exn 3 2 in
  let frame =
    {
      Web.kind = Web.Delta;
      rows = [ { Web.index = row 0; background = [ background 0 3 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "delta-partial" frame;
  [%expect {| delta-partial: valid |}]

let%expect_test "validate rejects a background gap" =
  let size = size_exn 3 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 0; background = [ background 0 1; background 2 3 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "gap" frame;
  [%expect {| gap: background-gap(row=0) |}]

let%expect_test "validate rejects a background span extending past the row's columns" =
  let size = size_exn 3 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 0; background = [ background 0 4; background 4 3 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "out-of-bounds-span" frame;
  [%expect {| out-of-bounds-span: background-invalid-span(row=0) |}]

let%expect_test "validate rejects a reversed background span" =
  let size = size_exn 3 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 0; background = [ background 2 1 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "reversed-span" frame;
  [%expect {| reversed-span: background-invalid-span(row=0) |}]

let%expect_test "validate rejects a background overlap" =
  let size = size_exn 3 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 0; background = [ background 0 2; background 1 3 ]; glyphs = [] } ];
      presentation = presentation size;
    }
  in
  check "overlap" frame;
  [%expect {| overlap: background-overlap(row=0) |}]

let%expect_test "validate rejects a glyph start so large that start + width overflows" =
  (* max_int as [start]: a naive [s + w > columns] check wraps this negative and would wrongly accept it.
     Types.Column.t is an unchecked non-negative int, so a hand-built frame can carry this value directly. *)
  let size = size_exn 1 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows =
        [
          {
            Web.index = row 0;
            background = [ background 0 1 ];
            glyphs = [ { Web.start = column max_int; width = Model.Unicode.One; text = "x"; style } ];
          };
        ];
      presentation = presentation size;
    }
  in
  check "overflow-glyph-start" frame;
  [%expect {| overflow-glyph-start: glyph-out-of-range((4611686018427387903,0)) |}]

let%expect_test "validate rejects an out-of-range glyph column" =
  let size = size_exn 3 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows = [ { Web.index = row 0; background = [ background 0 3 ]; glyphs = [ glyph 2 Model.Unicode.Two "x" ] } ];
      presentation = presentation size;
    }
  in
  check "out-of-range" frame;
  [%expect {| out-of-range: glyph-out-of-range((2,0)) |}]

let%expect_test "validate rejects two overlapping glyphs" =
  let size = size_exn 4 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows =
        [
          {
            Web.index = row 0;
            background = [ background 0 4 ];
            glyphs = [ glyph 0 Model.Unicode.Two "x"; glyph 1 Model.Unicode.One "y" ];
          };
        ];
      presentation = presentation size;
    }
  in
  check "glyph-overlap" frame;
  [%expect {| glyph-overlap: glyph-overlap((1,0)) |}]

let%expect_test "validate accepts an ordinary glyph sitting on its background span" =
  let size = size_exn 3 1 in
  let frame =
    {
      Web.kind = Web.Reset;
      rows =
        [
          {
            Web.index = row 0;
            background = [ background 0 3 ];
            glyphs = [ glyph 0 Model.Unicode.One "x"; glyph 1 Model.Unicode.One "y" ];
          };
        ];
      presentation = presentation size;
    }
  in
  check "glyph-on-background" frame;
  [%expect {| glyph-on-background: valid |}]
