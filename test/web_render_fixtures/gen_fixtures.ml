(* A native-only OCaml executable that builds and commits a handful of standalone edge-case frames as
   JSON fixtures under test/web_render_playwright/fixtures/*.json, for the Playwright suite to load
   directly (bypassing the bridge/trace machinery entirely) -- this is what catches DOM/CSS mapping
   bugs the native projection tests can't, since they never involve JavaScript. Mirrors
   test/web_rendering_codec/corpus.ml's technique: every frame is built by driving a real
   Tessera_renderer history (Set_style/Print/Erase/Move_cursor updates through Renderer.apply, then
   Web_frame.of_outcome), never hand-assembled as a record literal, so a background span's and its
   glyph's styles can never disagree the way a hand-built record could.

   Each fixture file is {"frames": [<html envelope>, ...]}: one entry for a single-frame case, two
   for a case proving a reset followed by a delta (a second Renderer.apply on the same session,
   projected via Web_frame.of_outcome ~patch:(Some ...)). *)

module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer.Renderer
module Style = Model.Style
module Update = Model.Update
module Mode = Model.Mode
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json

let uint_exn n = match Foundation.UInt.of_int n with Ok v -> v | Error _ -> assert false
let palette_index n = match Style.Palette_index.of_int n with Some p -> p | None -> assert false
let rgb ~red ~green ~blue = match Style.Rgb.make ~red ~green ~blue with Some c -> c | None -> assert false
let column n = Foundation.Types.Column.of_uint (uint_exn n)
let row n = Foundation.Types.Row.of_uint (uint_exn n)
let coord ~column:c ~row:r = Foundation.Types.coord ~column:(column c) ~row:(row r)

let policy_for ~columns ~rows =
  let limits =
    match
      Foundation.Limits.make ~max_columns:(uint_exn columns) ~max_control_bytes:(uint_exn 4096)
        ~max_csi_params:(uint_exn 16) ~max_diagnostics:(uint_exn 16) ~max_rows:(uint_exn rows)
        ~max_slice_bytes:(uint_exn 4096)
        ~max_snapshot_cells:(uint_exn (columns * rows))
    with
    | Ok l -> l
    | Error _ -> assert false
  in
  Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core

let size_of columns rows =
  match Foundation.Types.Size.make ~columns:(uint_exn columns) ~rows:(uint_exn rows) with
  | Ok s -> s
  | Error _ -> assert false

let full_style ~background ~foreground ~bold ~faint ~invisible ~inverse ~italic ~strikethrough ~underline : Style.delta
    =
  {
    background = Style.set background;
    foreground = Style.set foreground;
    bold = Style.set bold;
    faint = Style.set faint;
    invisible = Style.set invisible;
    inverse = Style.set inverse;
    italic = Style.set italic;
    strikethrough = Style.set strikethrough;
    underline = Style.set underline;
  }

let plain ?(background = Style.Default) ?(foreground = Style.Default) ?(bold = false) ?(faint = false)
    ?(invisible = false) ?(inverse = false) ?(italic = false) ?(strikethrough = false) ?(underline = false) () =
  full_style ~background ~foreground ~bold ~faint ~invisible ~inverse ~italic ~strikethrough ~underline

let set_style s = Update.Set_style s

let print_char c =
  Update.Print (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_char c)))

let print_scalar code =
  Update.Print (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int code)))

let print_scalars codes =
  Update.Print (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.of_scalars (List.map Uchar.of_int codes)))

let mode_delta_exn ~enabled n =
  match Mode.private_mode_delta ~enabled n with Some d -> d | None -> failwith "unrecognised private mode"

let cursor_visible_delta ~enabled = mode_delta_exn ~enabled 25 (* DECTCEM *)

let batch_of updates =
  List.fold_left
    (fun batch update -> Update.Batch.append batch (Update.Batch.singleton update))
    Update.Batch.empty updates

let next_lineage = ref 0

let fresh_lineage () =
  incr next_lineage;
  Foundation.Lineage_id.of_uint (uint_exn !next_lineage)

(* Invoked via `dune exec test/web_render_fixtures/gen_fixtures.exe` from the repository root (see
   the Makefile's `web-render-gen-fixtures` target), so this path is relative to the repo root, not
   this directory -- mirroring how `make node-pty-capture-traces` writes into its own source tree
   rather than a build artifact. Fixtures are a committed, explicit developer-generated corpus, like
   test/node_pty/traces/*.json, not a rule-produced build output. *)
let fixtures_dir = Filename.concat (Filename.concat "test" "web_render_playwright") "fixtures"

let fail name fmt =
  Printf.ksprintf
    (fun s ->
      Printf.eprintf "%s: %s\n" name s;
      exit 1)
    fmt

let encode_html name frame =
  (match Frame.validate frame with
  | Ok () -> ()
  | Error e -> fail name "invalid frame: %s" (Format.asprintf "%a" Frame.pp_error (Err.Error.kind e)));
  match Json.encode_html_frame (Json.html_envelope_of frame) with
  | Ok json -> json
  | Error e -> fail name "encode failed: %s" (Format.asprintf "%a" Json.E.pp_error (Err.Error.kind e))

let apply_batch name policy state updates =
  match Renderer.apply policy state (batch_of updates) with
  | Ok applied -> applied
  | Error e -> fail name "apply failed: %s" (Format.asprintf "%a" Renderer.pp_error (Err.Error.kind e))

let write_fixture name jsons =
  let path = Filename.concat fixtures_dir (name ^ ".json") in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      output_string oc "{\"frames\":[";
      output_string oc (String.concat "," jsons);
      output_string oc "]}\n")

let run_case name ~columns ~rows ~first ?second () =
  let policy = policy_for ~columns ~rows in
  let size = size_of columns rows in
  let initial = Renderer.initial ~lineage_id:(fresh_lineage ()) ~policy ~size in
  let applied1 = apply_batch name policy initial first in
  let snapshot1 = Renderer.snapshot applied1 in
  let frame1 =
    match Frame.of_outcome ~patch:None ~snapshot:snapshot1 with
    | Ok f -> f
    | Error e -> fail name "of_outcome (reset) failed: %s" (Format.asprintf "%a" Frame.pp_error (Err.Error.kind e))
  in
  let jsons = [ encode_html name frame1 ] in
  let jsons =
    match second with
    | None -> jsons
    | Some updates ->
        let state2 = Renderer.state applied1 in
        let applied2 = apply_batch name policy state2 updates in
        let patch2 = Renderer.patch applied2 in
        let snapshot2 = Renderer.snapshot applied2 in
        let frame2 =
          match Frame.of_outcome ~patch:(Some patch2) ~snapshot:snapshot2 with
          | Ok f -> f
          | Error e ->
              fail name "of_outcome (delta) failed: %s" (Format.asprintf "%a" Frame.pp_error (Err.Error.kind e))
        in
        jsons @ [ encode_html name frame2 ]
  in
  write_fixture name jsons

(* --- fixture cases --- *)

let () =
  (* RGB and indexed colours, on both foreground and background, across several cells. *)
  run_case "colors-rgb-indexed" ~columns:6 ~rows:1
    ~first:
      [
        set_style (plain ~foreground:(Style.Indexed (palette_index 3)) ());
        print_char 'A';
        set_style (plain ~foreground:(Style.Rgb (rgb ~red:200 ~green:50 ~blue:10)) ());
        print_char 'B';
        set_style (plain ~background:(Style.Indexed (palette_index 5)) ());
        print_char 'C';
        set_style (plain ~background:(Style.Rgb (rgb ~red:10 ~green:20 ~blue:200)) ());
        print_char 'D';
        set_style
          (plain
             ~foreground:(Style.Indexed (palette_index 200))
             ~background:(Style.Rgb (rgb ~red:1 ~green:2 ~blue:3))
             ());
        print_char 'E';
        set_style (plain ());
      ]
    ();

  (* Every rendition class individually, then an eighth cell combining all seven at once. *)
  run_case "rendition-classes" ~columns:8 ~rows:1
    ~first:
      [
        set_style (plain ~bold:true ());
        print_char 'A';
        set_style (plain ~faint:true ());
        print_char 'B';
        set_style (plain ~invisible:true ());
        print_char 'C';
        set_style (plain ~inverse:true ());
        print_char 'D';
        set_style (plain ~italic:true ());
        print_char 'E';
        set_style (plain ~strikethrough:true ());
        print_char 'F';
        set_style (plain ~underline:true ());
        print_char 'G';
        set_style
          (plain ~bold:true ~faint:true ~invisible:true ~inverse:true ~italic:true ~strikethrough:true ~underline:true
             ());
        print_char 'H';
      ]
    ();

  (* A coloured blank background: set a background colour, then erase the line with it -- a real
     terminal's route to a coloured blank cell, distinct from printing a space glyph. *)
  run_case "coloured-blank-background" ~columns:5 ~rows:1
    ~first:[ set_style (plain ~background:(Style.Indexed (palette_index 12)) ()); Update.Erase (Line `Clear_line) ]
    ();

  (* A combining-character grapheme: base scalar + combining acute, one grapheme instruction, not two
     cells. *)
  run_case "combining-grapheme" ~columns:4 ~rows:1 ~first:[ print_scalars [ 0x65; 0x0301 ]; print_char 'X' ] ();

  (* A wide glyph (a real CJK ideograph, U+4E00) at the row's right boundary: cols 2-3 of a 4-column
     row, so it touches the edge exactly and the cursor ends pending-wrap. *)
  run_case "wide-glyph-row-boundary" ~columns:4 ~rows:1
    ~first:[ print_char 'A'; print_char 'B'; print_scalar 0x4e00 ]
    ();

  (* Cursor visibility/pending-wrap states, each its own standalone frame. *)
  run_case "cursor-visible" ~columns:4 ~rows:1 ~first:[ print_char 'A'; print_char 'B' ] ();
  run_case "cursor-invisible" ~columns:4 ~rows:1
    ~first:[ print_char 'A'; Update.Set_mode (cursor_visible_delta ~enabled:false) ]
    ();
  run_case "cursor-pending-wrap" ~columns:3 ~rows:1 ~first:[ print_char 'A'; print_char 'B'; print_char 'C' ] ();

  (* A reset followed by a delta that replaces one full row: row 0 is printed first, then row 1 is
     printed in a second batch -- row 0 must be untouched by the delta. *)
  run_case "reset-then-delta-row" ~columns:4 ~rows:2
    ~first:[ print_char 'A'; print_char 'B' ]
    ~second:[ Update.Move_cursor (Position (coord ~column:0 ~row:1)); print_char 'C'; print_char 'D' ]
    ();

  (* A delta that only moves the cursor: no cell is written in the second batch, so the delta carries
     no row changes at all. *)
  run_case "delta-cursor-only" ~columns:4 ~rows:1
    ~first:[ print_char 'A'; print_char 'B' ]
    ~second:[ Update.Move_cursor (Forward (uint_exn 1)) ]
    ();

  (* (round-6) A reset with one title, followed by a delta with a different title and no row/cursor
     changes at all -- isolates the title-update path from row/cursor updates, since neither probe()
     nor a screenshot can observe document.title. *)
  run_case "reset-then-delta-title-only" ~columns:3 ~rows:1
    ~first:[ Update.Set_title "first title"; print_char 'A' ]
    ~second:[ Update.Set_title "second title" ] ()
