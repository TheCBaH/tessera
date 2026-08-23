module Foundation = Tessera_foundation
module Model = Tessera_model
open Tessera_test_support.Support

let uint_exn n = match Foundation.UInt.of_int n with Ok value -> value | Error _ -> invalid_arg "Generators.uint_exn"
let column_of_int n = Foundation.Types.Column.of_uint (uint_exn n)
let row_of_int n = Foundation.Types.Row.of_uint (uint_exn n)

let size_exn columns rows =
  match Foundation.Types.Size.make ~columns:(uint_exn columns) ~rows:(uint_exn rows) with
  | Ok value -> value
  | Error _ -> invalid_arg "Generators.size_exn"

let size_equal left right =
  Foundation.UInt.equal (Foundation.Types.Size.columns left) (Foundation.Types.Size.columns right)
  && Foundation.UInt.equal (Foundation.Types.Size.rows left) (Foundation.Types.Size.rows right)

let size_area size =
  Foundation.UInt.to_int (Foundation.Types.Size.columns size) * Foundation.UInt.to_int (Foundation.Types.Size.rows size)

let default_policy = match policy () with Ok value -> value | Error message -> failwith message
let lineage_of_int n = Foundation.Lineage_id.of_uint (uint_exn n)

(* QCheck.Gen sizes are always non-negative, so a size generator only needs to add one. *)
let dimension_gen bound = QCheck.Gen.map (fun n -> n + 1) (QCheck.Gen.int_bound (bound - 1))
let size_gen ~max_columns ~max_rows = QCheck.Gen.map2 size_exn (dimension_gen max_columns) (dimension_gen max_rows)

let coord_gen size =
  let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns size) in
  let rows = Foundation.UInt.to_int (Foundation.Types.Size.rows size) in
  QCheck.Gen.map2
    (fun column row -> Foundation.Types.coord ~column:(column_of_int column) ~row:(row_of_int row))
    (QCheck.Gen.int_bound (columns - 1))
    (QCheck.Gen.int_bound (rows - 1))

(** A representative sample of printable, control, and multi-byte fragments that exercise the decoder mapping table,
    mixed with single random bytes so that framing across chunk boundaries is exercised for both well-formed and
    malformed input. *)
let fragment_pool =
  [
    "A\xc3\xa9";
    (* "A", U+00E9 *)
    "\027[2;3H";
    "\027[m";
    "\027[31;1m";
    "\027[2J";
    "\027[?25h";
    "\027[?25l";
    "\027[?1049h";
    "\027[K";
    "\027[3P";
    "\027[2L";
    "\027]2;tessera\007";
    "\027]52;c;dGVzdA==\027\\";
    "\027Pdemo\027\\";
    "\xe4\xb8\xad";
    (* U+4E2D, a wide CJK grapheme *)
    "\xf0\x9f\x98\x80";
    (* U+1F600, an emoji grapheme *)
    "\xff\xfe";
    (* invalid UTF-8 lead bytes *)
    "\r\n\t\b";
  ]

let byte_gen =
  QCheck.Gen.oneof_weighted
    [
      (6, QCheck.Gen.map (fun code -> String.make 1 (Char.chr code)) (QCheck.Gen.int_range 0x20 0x7e));
      ( 2,
        QCheck.Gen.map
          (fun code -> String.make 1 (Char.chr code))
          (QCheck.Gen.oneof_list [ 0x1b; 0x07; 0x08; 0x09; 0x0a; 0x0d; 0x00 ]) );
      (1, QCheck.Gen.map (fun code -> String.make 1 (Char.chr code)) (QCheck.Gen.int_range 0 255));
    ]

let token_gen = QCheck.Gen.oneof_weighted [ (2, byte_gen); (3, QCheck.Gen.oneof_list fragment_pool) ]

let random_terminal_bytes =
  QCheck.Gen.map (String.concat "") (QCheck.Gen.list_size (QCheck.Gen.int_range 0 10) token_gen)

let split_points length =
  QCheck.Gen.map
    (fun points -> List.sort_uniq compare (0 :: length :: points))
    (QCheck.Gen.list_size (QCheck.Gen.int_range 0 6) (QCheck.Gen.int_range 0 length))

let chunks_of text points =
  let rec loop = function a :: (b :: _ as rest) -> String.sub text a (b - a) :: loop rest | _ -> [] in
  loop points

let text_with_splits_gen =
  QCheck.Gen.(
    random_terminal_bytes >>= fun text -> map (fun points -> (text, points)) (split_points (String.length text)))

let slice_exn text =
  match slice text with Ok value -> value | Error message -> invalid_arg ("Generators.slice_exn: " ^ message)

(* Bounded so that every generated batch stays comfortably within the default test policy limits
   (max_snapshot_cells, max_csi_params, etc.) regardless of the chosen renderer size. *)
let scalar_gen = QCheck.Gen.map Uchar.of_int (QCheck.Gen.int_range 0x21 0x7e)
let wide_scalar = Uchar.of_int 0x4e2d
let combining_scalar = Uchar.of_int 0x0301 (* combining acute accent, width zero *)

let print_gen =
  QCheck.Gen.map
    (fun scalar ->
      Model.Update.Print (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar scalar)))
    (QCheck.Gen.oneof_weighted
       [ (6, scalar_gen); (1, QCheck.Gen.return wide_scalar); (1, QCheck.Gen.return combining_scalar) ])

let move_gen ~columns ~rows =
  QCheck.Gen.map
    (fun move -> Model.Update.Move_cursor move)
    (QCheck.Gen.oneof
       [
         QCheck.Gen.map (fun n -> Model.Update.Back (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Forward (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Down (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Up (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Next_line (uint_exn n)) (QCheck.Gen.int_bound 2);
         QCheck.Gen.map (fun n -> Model.Update.Previous_line (uint_exn n)) (QCheck.Gen.int_bound 2);
         QCheck.Gen.map (fun c -> Model.Update.Column (column_of_int c)) (QCheck.Gen.int_bound (columns - 1));
         QCheck.Gen.map (fun r -> Model.Update.Row (row_of_int r)) (QCheck.Gen.int_bound (rows - 1));
         QCheck.Gen.map2
           (fun column row ->
             Model.Update.Position (Foundation.Types.coord ~column:(column_of_int column) ~row:(row_of_int row)))
           (QCheck.Gen.int_bound (columns - 1))
           (QCheck.Gen.int_bound (rows - 1));
       ])

let erase_gen =
  QCheck.Gen.map
    (fun erase -> Model.Update.Erase erase)
    (QCheck.Gen.oneof_list
       [
         Model.Update.Display `Clear_above;
         Model.Update.Display `Clear_all;
         Model.Update.Display `Clear_below;
         Model.Update.Line `Clear_left;
         Model.Update.Line `Clear_line;
         Model.Update.Line `Clear_right;
       ])

let edit_gen =
  QCheck.Gen.map
    (fun edit -> Model.Update.Edit edit)
    (QCheck.Gen.oneof
       [
         QCheck.Gen.map (fun n -> Model.Update.Delete_chars (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Delete_lines (uint_exn n)) (QCheck.Gen.int_bound 2);
         QCheck.Gen.map (fun n -> Model.Update.Erase_chars (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Insert_chars (uint_exn n)) (QCheck.Gen.int_bound 3);
         QCheck.Gen.map (fun n -> Model.Update.Insert_lines (uint_exn n)) (QCheck.Gen.int_bound 2);
       ])

let style_gen =
  let codes = [ 0; 1; 2; 3; 4; 7; 8; 9; 22; 23; 24; 27; 28; 29; 39; 49 ] in
  QCheck.Gen.map
    (fun code ->
      match Model.Style.sgr_delta code with Some delta -> Model.Update.Set_style delta | None -> Model.Update.Reset)
    (QCheck.Gen.oneof_list codes)

let mode_gen =
  let codes = [ (6, true); (6, false); (7, true); (7, false); (25, true); (25, false) ] in
  QCheck.Gen.map
    (fun (code, enabled) ->
      match Model.Mode.private_mode_delta ~enabled code with
      | Some delta -> Model.Update.Set_mode delta
      | None -> Model.Update.Reset)
    (QCheck.Gen.oneof_list codes)

let margins_gen ~rows =
  QCheck.Gen.map2
    (fun top bottom ->
      let top, bottom = if top <= bottom then (top, bottom) else (bottom, top) in
      Model.Update.Set_margins { top = row_of_int top; bottom = row_of_int bottom })
    (QCheck.Gen.int_bound (rows - 1))
    (QCheck.Gen.int_bound (rows - 1))

let update_gen size =
  let columns = Foundation.UInt.to_int (Foundation.Types.Size.columns size) in
  let rows = Foundation.UInt.to_int (Foundation.Types.Size.rows size) in
  QCheck.Gen.oneof
    [
      print_gen;
      move_gen ~columns ~rows;
      erase_gen;
      edit_gen;
      style_gen;
      mode_gen;
      margins_gen ~rows;
      QCheck.Gen.return Model.Update.Backspace;
      QCheck.Gen.return Model.Update.Carriage_return;
      QCheck.Gen.return Model.Update.Horizontal_tab;
      QCheck.Gen.return Model.Update.Line_feed;
      QCheck.Gen.return Model.Update.Save_cursor;
      QCheck.Gen.return Model.Update.Restore_cursor;
      QCheck.Gen.return Model.Update.Set_tab;
      QCheck.Gen.return Model.Update.Reset;
      QCheck.Gen.map (fun n -> Model.Update.Scroll_up (uint_exn n)) (QCheck.Gen.int_bound 2);
      QCheck.Gen.map (fun n -> Model.Update.Scroll_down (uint_exn n)) (QCheck.Gen.int_bound 2);
      QCheck.Gen.return (Model.Update.Alternate_screen `Enter_1049);
      QCheck.Gen.return (Model.Update.Alternate_screen `Leave_1049);
      QCheck.Gen.return (Model.Update.Switch_screen Foundation.Types.Primary);
      QCheck.Gen.return (Model.Update.Switch_screen Foundation.Types.Alternate);
      QCheck.Gen.map (fun n -> Model.Update.Set_title (Printf.sprintf "title-%d" n)) (QCheck.Gen.int_bound 9);
    ]

let updates_gen ~max_length size = QCheck.Gen.list_size (QCheck.Gen.int_bound max_length) (update_gen size)

let batch_of updates =
  List.fold_left
    (fun batch update -> Model.Update.Batch.append batch (Model.Update.Batch.singleton update))
    Model.Update.Batch.empty updates
