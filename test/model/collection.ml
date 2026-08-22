module Foundation = Tessera_foundation
module Model = Tessera_model
open Tessera_test_support.Support

let%expect_test "cell blocks and damage normalize deterministically" =
  let result =
    let* first = coord 0 0
    and* second = coord 1 0
    and* third = coord 0 1
    and* fourth = coord 1 1
    and* damage = rect 0 0 1 0
    and* overlap = rect 1 0 1 1 in
    let first_a = Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:first ~cell:(cell 0x41) in
    let first_b = Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:first ~cell:(cell 0x42) in
    let primary_second =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:second ~cell:(cell 0x44)
    in
    let primary_third =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:third ~cell:(cell 0x45)
    in
    let primary_fourth =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Primary ~coord:fourth ~cell:(cell 0x46)
    in
    let alternate =
      Model.Collection.Cell_block.make ~screen:Foundation.Types.Alternate ~coord:second ~cell:(cell 0x43)
    in
    let blocks =
      Model.Collection.Cell_blocks.of_list
        [ first_a; alternate; primary_second; primary_third; primary_fourth; first_b ]
    in
    let damages =
      Model.Collection.Damage.union
        (Model.Collection.Damage.singleton damage)
        (Model.Collection.Damage.singleton overlap)
    in
    Ok (blocks, damages)
  in
  Format.printf "%a@." (pp_result (Fmt.pair Model.Collection.Cell_blocks.pp Model.Collection.Damage.pp)) result;
  [%expect
    {|
    [cell-block(screen=alternate; rect={top=0; left=1; bottom=0; right=1}; cells=[{contents=glyph(<U+0043>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}]); cell-block(screen=primary; rect={top=0; left=0; bottom=1; right=1}; cells=[{contents=glyph(<U+0042>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=glyph(<U+0044>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=glyph(<U+0045>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; {contents=glyph(<U+0046>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]
    [{top=0; left=0; bottom=1; right=1}] |}]
