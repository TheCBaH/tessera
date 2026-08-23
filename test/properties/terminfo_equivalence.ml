(* Design claim "source/compiled Terminfo equivalence": for the legacy capability slots the compiled
   parser recognises, an equivalent source description and an independently hand-assembled compiled
   binary entry must parse to the same capability values. This complements the fixed fixtures in
   test/terminfo by generating many random capability subsets and values instead of one hard-coded
   entry. *)

let legacy =
  [
    ("clear", Tessera.Description.Clear_screen, 5);
    ("cup", Tessera.Description.Cursor_address, 10);
    ("cud1", Tessera.Description.Cursor_down, 11);
    ("cub1", Tessera.Description.Cursor_left, 14);
    ("cuf1", Tessera.Description.Cursor_right, 17);
    ("cuu1", Tessera.Description.Cursor_up, 19);
    ("ech", Tessera.Description.Erase_char, 37);
    ("el", Tessera.Description.Erase_line, 6);
  ]

let little_endian value = String.init 2 (fun index -> Char.chr ((value lsr (index * 8)) land 0xff))

(* A minimal, general version of the legacy-string layout used by test/fixtures/fixtures.ml: a
   fixed "demo" terminal name, no booleans/numbers, and a 38-slot legacy string offset table with
   the requested (index, value) entries present and every other slot absent (-1). *)
let build_compiled entries =
  let string_count = 38 in
  let offsets_by_index, string_table =
    List.fold_left
      (fun (offsets, table) (index, value) -> ((index, String.length table) :: offsets, table ^ value ^ "\000"))
      ([], "") entries
  in
  let offsets =
    String.concat ""
      (List.init string_count (fun index ->
           match List.assoc_opt index offsets_by_index with
           | Some offset -> little_endian offset
           | None -> little_endian 0xffff))
  in
  let names_bytes = "demo\000" in
  let names_size = String.length names_bytes in
  let padding = if (12 + names_size) land 1 = 1 then "\000" else "" in
  Bytes.of_string
    (little_endian 0x11a ^ little_endian names_size ^ little_endian 0 ^ little_endian 0 ^ little_endian string_count
    ^ little_endian (String.length string_table)
    ^ names_bytes ^ padding ^ offsets ^ string_table)

let value_char_gen =
  QCheck.Gen.oneof_list (List.init 26 (fun i -> Char.chr (97 + i)) @ List.init 10 (fun i -> Char.chr (48 + i)))

let value_gen = QCheck.Gen.string_size ~gen:value_char_gen (QCheck.Gen.int_range 1 6)

let arbitrary =
  QCheck.make
    (QCheck.Gen.list_size (QCheck.Gen.return (List.length legacy)) (QCheck.Gen.option value_gen))
    ~print:(fun options -> String.concat ";" (List.map (function Some value -> value | None -> "-") options))

let source_compiled_equivalence =
  QCheck.Test.make ~count:200 ~name:"source and compiled terminfo parsing agree on legacy capabilities" arbitrary
    (fun options ->
      let selection = List.combine legacy options in
      let present =
        List.filter_map
          (fun ((name, _capability, index), value) -> Option.map (fun value -> (name, index, value)) value)
          selection
      in
      let source_text = String.concat "," ("demo" :: List.map (fun (name, _, value) -> name ^ "=" ^ value) present) in
      let compiled_bytes = build_compiled (List.map (fun (_, index, value) -> (index, value)) present) in
      match
        ( Tessera.Terminfo.parse Generators.default_policy (Tessera.Terminfo.Source source_text),
          Tessera.Terminfo.parse Generators.default_policy (Tessera.Terminfo.Compiled compiled_bytes) )
      with
      | Ok source_description, Ok compiled_description ->
          List.for_all
            (fun (_, capability, _) ->
              Tessera.Description.Capability_map.find (Tessera.Description.capabilities source_description) capability
              = Tessera.Description.Capability_map.find
                  (Tessera.Description.capabilities compiled_description)
                  capability)
            legacy
      | Error _, _ | _, Error _ -> QCheck.Test.fail_report "terminfo parse reported an error for generated input")

let tests = [ source_compiled_equivalence ]
