let ( let* ) = Result.bind

let ( and* ) left right =
  let* left = left in
  let* right = right in
  Ok (left, right)

let with_error pp result = Result.map_error (Format.asprintf "%a" pp) result
let uint value = with_error Tessera.UInt.E.Error.pp (Tessera.UInt.of_int value)

let policy () =
  let* max_columns = uint 80
  and* max_control_bytes = uint 1024
  and* max_csi_params = uint 16
  and* max_diagnostics = uint 16
  and* max_rows = uint 24
  and* max_slice_bytes = uint 4096
  and* max_snapshot_cells = uint 1920 in
  let* limits =
    with_error Tessera.Limits.E.Error.pp
      (Tessera.Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows ~max_slice_bytes
         ~max_snapshot_cells)
  in
  Ok (Tessera.Policy.make ~limits ~profile:Tessera.Policy.Xterm_256color_core)

let size () =
  let* columns = uint 2 and* rows = uint 1 in
  with_error Tessera.Types.E.Error.pp (Tessera.Types.Size.make ~columns ~rows)

let slice text =
  let bytes = Bytes.of_string text in
  let* off = uint 0 and* len = uint (Bytes.length bytes) in
  with_error Tessera.Types.E.Error.pp (Tessera.Types.slice bytes ~off ~len)

let little_endian value = String.init 2 (fun index -> Char.chr ((value lsr (index * 8)) land 0xff))

let batch_of_updates updates =
  List.fold_left
    (fun batch update -> Tessera.Update.Batch.append batch (Tessera.Update.Batch.singleton update))
    Tessera.Update.Batch.empty updates

let compiled_terminfo_fixture () =
  let offsets =
    String.init (38 * 2) (fun index ->
        let capability = index / 2 and byte = index mod 2 in
        match (capability, byte) with 5, _ -> '\000' | 10, 0 -> '\005' | 10, _ -> '\000' | _, _ -> '\255')
  in
  Bytes.of_string
    (little_endian 0x11a ^ little_endian 5 ^ little_endian 0 ^ little_endian 0 ^ little_endian 38 ^ little_endian 22
   ^ "demo\000\000" ^ offsets ^ "\027[2J\000\027[%i%p1%d;%p2%dH\000")

let malformed_compiled_terminfo_fixture () =
  let offsets = Bytes.make (39 * 2) '\255' in
  Bytes.set offsets (38 * 2) '\001';
  Bytes.of_string
    (little_endian 0x11a ^ little_endian 5 ^ little_endian 0 ^ little_endian 0 ^ little_endian 39 ^ little_endian 1
   ^ "demo\000\000" ^ Bytes.to_string offsets ^ "\000")

let extended_compiled_terminfo_fixture () =
  let offsets =
    String.init (38 * 2) (fun index ->
        let capability = index / 2 and byte = index mod 2 in
        match (capability, byte) with 5, _ -> '\000' | _, _ -> '\255')
  in
  Bytes.of_string
    (little_endian 0x21e ^ little_endian 5 ^ little_endian 0 ^ little_endian 0 ^ little_endian 38 ^ little_endian 6
   ^ "demo\000\000" ^ offsets ^ "\027[2J\000\000" ^ little_endian 1 ^ little_endian 1 ^ little_endian 1
   ^ little_endian 4 ^ little_endian 15 ^ "\001\000" ^ "\042\000\000\000" ^ little_endian 0 ^ little_endian 6
   ^ little_endian 9 ^ little_endian 12 ^ "value\000xb\000xn\000xs\000")

let malformed_extended_compiled_terminfo_fixture () =
  let bytes = extended_compiled_terminfo_fixture () in
  Bytes.set bytes 118 '\255';
  Bytes.set bytes 119 '\255';
  bytes

let%expect_test "public facade decodes and renders output" =
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 and* slice = slice "A\027]2;tessera\007" in
    let session = Tessera.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    with_error Tessera.Session.E.Error.pp (Tessera.ingest session (Tessera.Bytes slice))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.pp_outcome ~error:Format.pp_print_string) result;
  [%expect
    {| {items=[update(print([<U+0041>])); update(set-title("tessera"))]; patch={lineage=1; before=0; after=1; before-size=2×1; cells=[cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=0}; cells=[{contents=glyph(<U+0041>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=0}]; presentation={active=keep; cursor=set({position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}); cursor-visible=keep; title=set(some("tessera"))}; size=keep}; snapshot=snapshot(active=primary; cursor=((1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=true; lineage=1; generation=1; size=2×1; title=some("tessera"))} |}]

let%expect_test "public facade canonicalizes terminal capabilities" =
  let result =
    let* earlier =
      with_error Tessera.Description.E.Error.pp
        (Tessera.Description.Capability_map.of_list [ (Tessera.Description.Clear_screen, "\027[2J") ])
    in
    let* later =
      with_error Tessera.Description.E.Error.pp
        (Tessera.Description.Capability_map.of_list [ (Tessera.Description.Cursor_address, "\027[%i%p1%d;%p2%dH") ])
    in
    with_error Tessera.Description.E.Error.pp (Tessera.Description.Capability_map.merge ~earlier ~later)
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.Capability_map.pp ~error:Format.pp_print_string) result;
  [%expect {| [clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"] |}]

let%expect_test "public facade parses terminfo source escapes" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo|portable,clear=\\E[2J,cup=\\E[%i%p1%d;%p2%dH,"))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| description(capabilities=[clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"]) |}]

let%expect_test "public facade preserves escaped terminfo field delimiters" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,tsl=title\\,value,"))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| description(capabilities=[set-title="title,value"]) |}]

let%expect_test "public facade retains source names and extension fields" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.parse policy
         (Tessera.Terminfo.Source
            "# comment, ignored\ndemo|portable,am,cols#80,clear=\\E[2J,clear@,xfoo=title\\,value,use=base,"))
  in
  let pp_description ppf description =
    let pp_name ppf name = Format.fprintf ppf "%S" name in
    let pp_extension ppf (name, value) = Format.fprintf ppf "%s=%a" name Tessera.Description.pp_extension_value value in
    Format.fprintf ppf "names=[%a]@.extensions=[%a]@.uses=[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_name)
      (Tessera.Description.names description)
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_extension)
      (Tessera.Description.extensions description)
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_name)
      (Tessera.Description.uses description)
  in
  Format.printf "%a@." (Fmt.result ~ok:pp_description ~error:Format.pp_print_string) result;
  [%expect
    {|
    names=["demo"; "portable"]
    extensions=[am=boolean; cols=number(80); clear=cancelled; xfoo=string("title,value")]
    uses=["base"] |}]

let%expect_test "public facade reports source escape locations" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp_kind
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,\n  clear=\\q,"))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| source syntax: line 2, column 3: invalid escape |}]

let%expect_test "public facade resolves terminfo use dependencies" =
  let result =
    let* policy = policy () in
    let* base =
      with_error Tessera.Terminfo.E.Error.pp
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "base,clear=\\E[2J,"))
    in
    let* child =
      with_error Tessera.Terminfo.E.Error.pp
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "child,use=base,cup=\\E[%i%p1%d;%p2%dH,"))
    in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.resolve_use child ~lookup:(fun name -> if name = "base" then Some base else None))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| description(capabilities=[clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"]) |}]

let%expect_test "public facade preserves source extensions through terminfo use resolution" =
  let result =
    let* policy = policy () in
    let* base =
      with_error Tessera.Terminfo.E.Error.pp (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "base,am,"))
    in
    let* child =
      with_error Tessera.Terminfo.E.Error.pp (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "child,use=base,"))
    in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.resolve_use child ~lookup:(fun name -> if name = "base" then Some base else None))
  in
  let pp_description ppf description =
    Format.fprintf ppf "names=[%a]@.extensions=[%a]"
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf name -> Format.fprintf ppf "%S" name))
      (Tessera.Description.names description)
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf (name, value) -> Format.fprintf ppf "%s=%a" name Tessera.Description.pp_extension_value value))
      (Tessera.Description.extensions description)
  in
  Format.printf "%a@." (Fmt.result ~ok:pp_description ~error:Format.pp_print_string) result;
  [%expect {|
    names=["child"]
    extensions=[am=boolean] |}]

let%expect_test "public facade parses baseline compiled terminfo" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Compiled (compiled_terminfo_fixture ())))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {|
    description(capabilities=[clear-screen="\027[2J"; cursor-address="\027[%i%p1%d;%p2%dH"]) |}]

let%expect_test "public facade parses extended compiled terminfo data" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Compiled (extended_compiled_terminfo_fixture ())))
  in
  let pp_description ppf description =
    Format.fprintf ppf "description=%a@.names=[%a]@.extensions=[%a]" Tessera.Description.pp description
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf name -> Format.fprintf ppf "%S" name))
      (Tessera.Description.names description)
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf (name, value) -> Format.fprintf ppf "%s=%a" name Tessera.Description.pp_extension_value value))
      (Tessera.Description.extensions description)
  in
  Format.printf "%a@." (Fmt.result ~ok:pp_description ~error:Format.pp_print_string) result;
  [%expect
    {|
    description=description(capabilities=[clear-screen="\027[2J"])
    names=["demo"]
    extensions=[xb=boolean; xn=number(42); xs=string("value")] |}]

let%expect_test "public facade validates every compiled string offset" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp_kind
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Compiled (malformed_compiled_terminfo_fixture ())))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| compiled format: invalid compiled string offset |}]

let%expect_test "public facade validates every extended capability name offset" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp_kind
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Compiled (malformed_extended_compiled_terminfo_fixture ())))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| compiled format: missing extended capability name |}]

let%expect_test "public facade reports unresolved terminfo use" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "child,use=missing,"))
    in
    with_error Tessera.Terminfo.E.Error.pp_kind (Tessera.Terminfo.resolve_use description ~lookup:(fun _ -> None))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| source syntax: unknown use="missing" |}]

let%expect_test "public facade encodes capability-backed updates" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy
           (Tessera.Terminfo.Source "demo,clear=\\E[2J,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let* count = uint 2 and* column = uint 3 and* row = uint 1 in
    let position =
      Tessera.Types.coord ~column:(Tessera.Types.Column.of_uint column) ~row:(Tessera.Types.Row.of_uint row)
    in
    let batch =
      Tessera.Update.Batch.append
        (Tessera.Update.Batch.singleton (Tessera.Update.Move_cursor (Tessera.Update.Position position)))
        (Tessera.Update.Batch.append
           (Tessera.Update.Batch.singleton (Tessera.Update.Edit (Tessera.Update.Erase_chars count)))
           (Tessera.Update.Batch.singleton Tessera.Update.Reset))
    in
    with_error Tessera.Encoder.E.Error.pp_kind (Tessera.Encoder.encode description policy batch)
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| ["\027[2;4H"; "\027[2X"; "\027[2J"] |}]

let%expect_test "public facade encodes every controlled release-one update" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy
           (Tessera.Terminfo.Source "demo,clear=C,el=E,ech=X%p1%d,cup=P%p1%d\\,%p2%d,cud1=D,cub1=L,cuf1=R,cuu1=U,"))
    in
    let* count = uint 2 and* column = uint 3 and* row = uint 1 in
    let position =
      Tessera.Types.coord ~column:(Tessera.Types.Column.of_uint column) ~row:(Tessera.Types.Row.of_uint row)
    in
    let graphemes =
      Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))
    in
    let batch =
      batch_of_updates
        [
          Tessera.Update.Reset;
          Tessera.Update.Erase (Tessera.Update.Display `Clear_all);
          Tessera.Update.Erase (Tessera.Update.Line `Clear_right);
          Tessera.Update.Edit (Tessera.Update.Erase_chars count);
          Tessera.Update.Move_cursor (Tessera.Update.Position position);
          Tessera.Update.Move_cursor (Tessera.Update.Up count);
          Tessera.Update.Move_cursor (Tessera.Update.Down count);
          Tessera.Update.Move_cursor (Tessera.Update.Back count);
          Tessera.Update.Move_cursor (Tessera.Update.Forward count);
          Tessera.Update.Print graphemes;
        ]
    in
    with_error Tessera.Encoder.E.Error.pp_kind (Tessera.Encoder.encode description policy batch)
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| ["C"; "C"; "E"; "X2"; "P1,3"; "U"; "U"; "D"; "D"; "L"; "L"; "R"; "R"; "A"] |}]

let%expect_test "public facade rejects an empty repeated capability" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,cuu1=,"))
    in
    let* count = uint 1 in
    with_error Tessera.Encoder.E.Error.pp_kind
      (Tessera.Encoder.encode description policy
         (Tessera.Update.Batch.singleton (Tessera.Update.Move_cursor (Tessera.Update.Up count))))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| unexpressible update: move-cursor(up(1)) |}]

let%expect_test "public facade rejects unsupported terminfo capability operations" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,ech=\\E[%{1}%dX,"))
    in
    let* count = uint 1 in
    with_error Tessera.Encoder.E.Error.pp_kind
      (Tessera.Encoder.encode description policy
         (Tessera.Update.Batch.singleton (Tessera.Update.Edit (Tessera.Update.Erase_chars count))))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| unexpressible update: edit(erase-chars(1)) |}]

let%expect_test "public facade encodes documented literal percent operations" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,clear=\\E[%%2J,"))
    in
    with_error Tessera.Encoder.E.Error.pp_kind
      (Tessera.Encoder.encode description policy (Tessera.Update.Batch.singleton Tessera.Update.Reset))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| ["\027[%2J"] |}]

let%expect_test "public facade reports unexpressible updates" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,clear=\\E[2J,"))
    in
    with_error Tessera.Encoder.E.Error.pp_kind
      (Tessera.Encoder.encode description policy (Tessera.Update.Batch.singleton Tessera.Update.Horizontal_tab))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| unexpressible update: horizontal-tab |}]

let%expect_test "public facade repaints a glyph patch into terminal bytes" =
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let renderer = Tessera.Renderer.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let printed =
      Tessera.Renderer.apply policy renderer
        (Tessera.Update.Batch.singleton
           (Tessera.Update.Print
              (Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)))))
    in
    let* applied = with_error Tessera.Renderer.E.Error.pp_kind printed in
    let target = Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* target, batch =
      with_error Tessera.Repaint.E.Error.pp_kind
        (Tessera.Repaint.compile description policy target (Tessera.Renderer.patch applied))
    in
    let* chunks = with_error Tessera.Encoder.E.Error.pp_kind (Tessera.Encoder.encode description policy batch) in
    Ok (target, chunks)
  in
  Format.printf "%a@."
    (Fmt.result ~ok:(Fmt.pair Tessera.Repaint.pp_target Tessera.Encoder.pp_byte_chunks) ~error:Format.pp_print_string)
    result;
  [%expect
    {|
    target(active=primary; cells=1; cursor={position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; cursor-visible=true; lineage=1; generation=1; modes={auto_wrap=true; cursor_visible=true; insert=false; origin=false}; size=2×1; title=none)
    ["\027[1;1H"; "A"; "\027[1;2H"] |}]

let%expect_test "public facade round trips controlled repaintable patches" =
  let controlled_round_trip ~description ~policy ~target ~before source =
    let* _, repaint =
      with_error Tessera.Repaint.E.Error.pp_kind
        (Tessera.Repaint.compile description policy target (Tessera.Renderer.patch source))
    in
    let* chunks = with_error Tessera.Encoder.E.Error.pp_kind (Tessera.Encoder.encode description policy repaint) in
    let* continuation, items =
      Tessera.Encoder.fold_chunks
        (fun result chunk ->
          let* continuation, items = result in
          let* decoded = with_error Tessera.Decoder.E.Error.pp_kind (Tessera.Decoder.feed policy continuation chunk) in
          Ok (decoded.continuation, Tessera.Effect.Item_sequence.append items decoded.items))
        (Ok (Tessera.Decoder.initial, Tessera.Effect.Item_sequence.empty))
        chunks
    in
    let* finished = with_error Tessera.Decoder.E.Error.pp_kind (Tessera.Decoder.finish policy continuation) in
    let items = Tessera.Effect.Item_sequence.append items finished.items in
    let* updates =
      Tessera.Effect.Item_sequence.fold_left
        (fun result item ->
          let* updates = result in
          match item with
          | Tessera.Effect.Update update ->
              Ok (Tessera.Update.Batch.append updates (Tessera.Update.Batch.singleton update))
          | Tessera.Effect.Observation _ -> Error "unexpected decoder observation")
        (Ok Tessera.Update.Batch.empty) items
    in
    let* output = with_error Tessera.Renderer.E.Error.pp_kind (Tessera.Renderer.apply policy before updates) in
    Ok
      ( Tessera.Patch.normalize (Tessera.Renderer.patch source) = Tessera.Patch.normalize (Tessera.Renderer.patch output),
        Tessera.Renderer.snapshot source = Tessera.Renderer.snapshot output )
  in
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 and* one = uint 1 in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let initial = Tessera.Renderer.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let target = Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* glyph =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy initial
           (Tessera.Update.Batch.singleton
              (Tessera.Update.Print
                 (Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))))))
    in
    let* glyph = controlled_round_trip ~description ~policy ~target ~before:initial glyph in
    let* seeded =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy initial
           (Tessera.Update.Batch.singleton
              (Tessera.Update.Print
                 (Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41))))))
    in
    let* seeded_target, _ =
      with_error Tessera.Repaint.E.Error.pp_kind
        (Tessera.Repaint.compile description policy target (Tessera.Renderer.patch seeded))
    in
    let* zero = uint 0 in
    let position =
      Tessera.Types.coord ~column:(Tessera.Types.Column.of_uint zero) ~row:(Tessera.Types.Row.of_uint zero)
    in
    let* erased =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy (Tessera.Renderer.state seeded)
           (batch_of_updates
              [
                Tessera.Update.Move_cursor (Tessera.Update.Position position);
                Tessera.Update.Edit (Tessera.Update.Erase_chars one);
              ]))
    in
    let* erased =
      controlled_round_trip ~description ~policy ~target:seeded_target ~before:(Tessera.Renderer.state seeded) erased
    in
    let* wide_columns = uint 3 in
    let* wide_size = with_error Tessera.Types.E.Error.pp (Tessera.Types.Size.make ~columns:wide_columns ~rows:one) in
    let wide_initial =
      Tessera.Renderer.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size:wide_size
    in
    let wide_target =
      Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size:wide_size
    in
    let* wide =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy wide_initial
           (Tessera.Update.Batch.singleton
              (Tessera.Update.Print
                 (Tessera.Unicode.Grapheme_sequence.singleton
                    (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x4e00))))))
    in
    let* wide = controlled_round_trip ~description ~policy ~target:wide_target ~before:wide_initial wide in
    Ok (glyph, erased, wide)
  in
  let pp_round_trip ppf (glyph, erased, wide) =
    let pp_case name ppf (patch, projection) = Format.fprintf ppf "%s: patch=%b; projection=%b" name patch projection in
    Format.fprintf ppf "%a@.%a@.%a" (pp_case "glyph") glyph (pp_case "erase") erased (pp_case "wide") wide
  in
  Format.printf "%a@." (Fmt.result ~ok:pp_round_trip ~error:Format.pp_print_string) result;
  [%expect
    {|
    glyph: patch=true; projection=true
    erase: patch=true; projection=true
    wide: patch=true; projection=true |}]

let%expect_test "public facade repaints a resize full projection into an owned target" =
  let result =
    let* policy = policy () and* lineage = uint 1 and* columns = uint 2 and* rows = uint 1 and* resized_rows = uint 2 in
    let* size = with_error Tessera.Types.E.Error.pp (Tessera.Types.Size.make ~columns ~rows) in
    let* resized_size = with_error Tessera.Types.E.Error.pp (Tessera.Types.Size.make ~columns ~rows:resized_rows) in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy
           (Tessera.Terminfo.Source "demo,clear=\\E[2J,cup=\\E[%i%p1%d;%p2%dH,ech=\\E[%p1%dX,"))
    in
    let renderer = Tessera.Renderer.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* applied =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy renderer (Tessera.Update.Batch.singleton (Tessera.Update.Resize resized_size)))
    in
    let target = Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* target, batch =
      with_error Tessera.Repaint.E.Error.pp_kind
        (Tessera.Repaint.compile description policy target (Tessera.Renderer.patch applied))
    in
    let* chunks = with_error Tessera.Encoder.E.Error.pp_kind (Tessera.Encoder.encode description policy batch) in
    Ok (target, chunks)
  in
  Format.printf "%a@."
    (Fmt.result ~ok:(Fmt.pair Tessera.Repaint.pp_target Tessera.Encoder.pp_byte_chunks) ~error:Format.pp_print_string)
    result;
  [%expect
    {|
    target(active=primary; cells=4; cursor={position=(0,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}; cursor-visible=true; lineage=1; generation=1; modes={auto_wrap=true; cursor_visible=true; insert=false; origin=false}; size=2×2; title=none)
    ["\027[2J"; "\027[1;1H"; "\027[1X"; "\027[1;2H"; "\027[1X"; "\027[2;1H"; "\027[1X"; "\027[2;2H"; "\027[1X"; "\027[1;1H"] |}]

let%expect_test "public facade rejects uncontrolled repaint projections before encoding" =
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 and* zero = uint 0 in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,cup=\\E[%i%p1%d;%p2%dH,"))
    in
    let lineage_id = Tessera.Lineage_id.of_uint lineage in
    let renderer = Tessera.Renderer.initial ~lineage_id ~policy ~size in
    let bold = match Tessera.Style.sgr_delta 1 with Some value -> value | None -> assert false in
    let* styled =
      with_error Tessera.Renderer.E.Error.pp_kind
        (Tessera.Renderer.apply policy renderer
           (batch_of_updates
              [
                Tessera.Update.Set_style bold;
                Tessera.Update.Print
                  (Tessera.Unicode.Grapheme_sequence.singleton (Tessera.Unicode.grapheme_of_scalar (Uchar.of_int 0x41)));
                Tessera.Update.Set_style Tessera.Style.reset_delta;
              ]))
    in
    let* after_generation = with_error Tessera.UInt.E.Error.pp (Tessera.Generation.succ Tessera.Generation.zero) in
    let position =
      Tessera.Types.coord ~column:(Tessera.Types.Column.of_uint zero) ~row:(Tessera.Types.Row.of_uint zero)
    in
    let incomplete_wide =
      Tessera.Patch.make ~after_generation ~before_generation:Tessera.Generation.zero ~before_size:size
        ~cells:
          (Tessera.Collection.Cell_blocks.of_list
             [
               Tessera.Collection.Cell_block.make ~screen:Tessera.Types.Primary ~coord:position
                 ~cell:(Tessera.Cell.wide_continuation ~line_id:Tessera.Line_id.zero ~style:Tessera.Style.default);
             ])
        ~damage:Tessera.Collection.Damage.empty ~lineage_id
        ~presentation:
          {
            active = Tessera.Patch.Keep;
            cursor = Tessera.Patch.Keep;
            cursor_visible = Tessera.Patch.Keep;
            title = Tessera.Patch.Keep;
          }
        ~size:Tessera.Patch.Keep
    in
    let rejected target patch =
      match Tessera.Repaint.compile description policy target patch with
      | Ok _ -> "accepted"
      | Error error -> Format.asprintf "%a" Tessera.Repaint.E.Error.pp_kind error
    in
    let target = Tessera.Repaint.initial ~lineage_id ~policy ~size in
    let wrong_target = Tessera.Repaint.initial ~lineage_id:(Tessera.Lineage_id.of_uint zero) ~policy ~size in
    Ok
      ( rejected target (Tessera.Renderer.patch styled),
        rejected target incomplete_wide,
        rejected wrong_target incomplete_wide )
  in
  let pp_rejected ppf (style, wide, lineage) = Format.fprintf ppf "style=%s@.wide=%s@.lineage=%s" style wide lineage in
  Format.printf "%a@." (Fmt.result ~ok:pp_rejected ~error:Format.pp_print_string) result;
  [%expect {|
    style=unsupported presentation
    wide=incomplete wide pair
    lineage=lineage mismatch |}]

let%expect_test "public facade rejects malformed terminfo escapes" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp_kind
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,clear=\\q,"))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {|
    source syntax: line 1, column 6: invalid escape |}]
