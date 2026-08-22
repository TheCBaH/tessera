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

(* Public construction and aliases are exercised implicitly by every test below via
   [Tessera.initial]/[Tessera.Lineage_id]/[Tessera.UInt] etc. — the facade's re-exports are the
   thing under test throughout this file, not a single dedicated case. *)

let%expect_test "public facade decodes and renders output" =
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 and* slice = slice "A\027]2;tessera\007" in
    let session = Tessera.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    with_error Tessera.Session.E.Error.pp (Tessera.ingest session (Tessera.Bytes slice))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.pp_outcome ~error:Format.pp_print_string) result;
  [%expect
    {| {items=[update(print([<U+0041>])); update(set-title("tessera"))]; patch={lineage=1; before=0; after=1; before-size=2×1; cells=[cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=0}; cells=[{contents=glyph(<U+0041>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=0}]; presentation={active=keep; cursor=set({position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}); cursor-visible=keep; title=set(some("tessera"))}; size=keep}; snapshot=snapshot(active=primary; cursor=((1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=true; lineage=1; generation=1; size=2×1; title=some("tessera"))} |}]

let%expect_test "public facade resize ingress is ordered and observable" =
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 and* slice = slice "A" in
    let initial = Tessera.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* pending = with_error Tessera.Session.E.Error.pp (Tessera.ingest initial (Tessera.Bytes slice)) in
    with_error Tessera.Session.E.Error.pp
      (Tessera.ingest (Tessera.session pending) (Tessera.Out_of_band (Tessera.Resize size)))
  in
  Format.printf "%a@."
    (Fmt.result ~ok:Tessera.Effect.Item_sequence.pp ~error:Format.pp_print_string)
    (Result.map Tessera.outcome_items result);
  [%expect {| [observation(resize(2×1))] |}]

let%expect_test "public facade finish flushes the final grapheme" =
  let result =
    let* policy = policy () and* size = size () and* lineage = uint 1 and* slice = slice "A" in
    let session = Tessera.initial ~lineage_id:(Tessera.Lineage_id.of_uint lineage) ~policy ~size in
    let* next =
      Result.map Tessera.session (with_error Tessera.Session.E.Error.pp (Tessera.ingest session (Tessera.Bytes slice)))
    in
    with_error Tessera.Session.E.Error.pp (Tessera.finish next)
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.pp_outcome ~error:Format.pp_print_string) result;
  [%expect
    {| {items=[update(print([<U+0041>]))]; patch={lineage=1; before=1; after=2; before-size=2×1; cells=[cell-block(screen=primary; rect={top=0; left=0; bottom=0; right=0}; cells=[{contents=glyph(<U+0041>); line_id=0; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}])]; damage=[{top=0; left=0; bottom=0; right=0}]; presentation={active=keep; cursor=set({position=(1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}}); cursor-visible=keep; title=keep}; size=keep}; snapshot=snapshot(active=primary; cursor=((1,0); pending-wrap=false; style={background=default; foreground=default; bold=false; faint=false; invisible=false; inverse=false; italic=false; strikethrough=false; underline=false}); cursor-visible=true; lineage=1; generation=2; size=2×1; title=none)} |}]

let%expect_test "public facade parses a description and encodes an update" =
  let result =
    let* policy = policy () in
    let* description =
      with_error Tessera.Terminfo.E.Error.pp_kind
        (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,clear=\\E[2J,"))
    in
    with_error Tessera.Encoder.E.Error.pp_kind
      (Tessera.Encoder.encode description policy (Tessera.Update.Batch.singleton Tessera.Update.Reset))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Encoder.pp_byte_chunks ~error:Format.pp_print_string) result;
  [%expect {| ["\027[2J"] |}]

let%expect_test "public facade rejects a malformed terminfo escape" =
  let result =
    let* policy = policy () in
    with_error Tessera.Terminfo.E.Error.pp_kind
      (Tessera.Terminfo.parse policy (Tessera.Terminfo.Source "demo,clear=\\q,"))
  in
  Format.printf "%a@." (Fmt.result ~ok:Tessera.Description.pp ~error:Format.pp_print_string) result;
  [%expect {| source syntax: line 1, column 6: invalid escape |}]
