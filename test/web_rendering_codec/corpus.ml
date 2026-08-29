(* Shared corpus, compiled natively and to js_of_ocaml/Melange (see ./dune), proving lib/web_rendering itself --
   not just the underlying JSON codec (test/json_codec) -- produces byte-identical output on all three runtimes.

   Unlike an earlier version of this corpus, the frame is built by driving a real Tessera_renderer history
   (Set_style/Print updates through Renderer.apply, then Web_frame.of_outcome), not hand-assembled as a
   Web_frame.t record literal. That matters for two reasons: (1) a hand-built record can only ever put a glyph's
   style and its covering background span's style in agreement by convention, whereas Renderer.cells actually
   enforces it (both come from the same cell), so driving real updates is the only way to exercise Web_canvas's
   colour/decoration derivation (drawn from each *background* span's style, see web_canvas.ml's background_ops)
   the way it truly arises; and (2) it lets this corpus include a real multi-byte UTF-8 grapheme (U+4E00) as
   actual terminal content passed through Update.Print, rather than an ASCII stand-in.

   The printed lines are hex-encoded rather than raw text, because Melange represents OCaml's byte-oriented
   [string] as a native JS (UTF-16) string with one JS code unit per OCaml byte -- so a byte like 0xe4 becomes
   the JS code unit U+00E4. Melange's own stdout write (`process.stdout.write`, in its generated `caml_io.js`)
   then re-encodes that code unit as UTF-8 *text*, expanding it to two output bytes instead of writing the
   original single byte back out (confirmed by inspecting the generated JS and the actual bytes `node` writes
   for this exact input). That bug lives in Melange's stdout channel implementation, not in this library's
   encoded value (which is correct and identical in memory on all three backends); hex-encoding the print
   transport removes that unrelated confound, since every hex digit is plain ASCII and survives Melange's
   stdout path unchanged, while still comparing the underlying encoded bytes exactly (see
   test/json_codec/corpus.ml, which documents and applies the same fix). *)

module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer.Renderer
module Style = Model.Style
module Update = Model.Update
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json

let uint_exn n = match Foundation.UInt.of_int n with Ok v -> v | Error _ -> assert false
let palette_index n = match Style.Palette_index.of_int n with Some p -> p | None -> assert false
let rgb ~red ~green ~blue = match Style.Rgb.make ~red ~green ~blue with Some c -> c | None -> assert false

let policy =
  let limits =
    match
      Foundation.Limits.make ~max_columns:(uint_exn 80) ~max_control_bytes:(uint_exn 1024) ~max_csi_params:(uint_exn 16)
        ~max_diagnostics:(uint_exn 16) ~max_rows:(uint_exn 24) ~max_slice_bytes:(uint_exn 4096)
        ~max_snapshot_cells:(uint_exn 1920)
    with
    | Ok l -> l
    | Error _ -> assert false
  in
  Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core

let size =
  match Foundation.Types.Size.make ~columns:(uint_exn 6) ~rows:(uint_exn 1) with Ok s -> s | Error _ -> assert false

(* A fully-determined style delta: every field is [Set _], so applying it fixes the resultant pen style outright
   regardless of what came before (like a real terminal's SGR reset-then-set sequence), rather than depending on
   [Style.apply_delta]'s composition with whatever the previous [Set_style] left behind. *)
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

let print_char c =
  Update.Print (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_char c)))

let print_scalar code =
  Update.Print (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int code)))

let updates =
  [
    (* col 0: Indexed foreground, bold + underline. *)
    Update.Set_style
      (full_style ~background:Style.Default
         ~foreground:(Style.Indexed (palette_index 3))
         ~bold:true ~faint:false ~invisible:false ~inverse:false ~italic:false ~strikethrough:false ~underline:true);
    print_char 'A';
    (* col 1: Rgb background, inverse + italic + strikethrough. *)
    Update.Set_style
      (full_style
         ~background:(Style.Rgb (rgb ~red:10 ~green:20 ~blue:30))
         ~foreground:Style.Default ~bold:false ~faint:false ~invisible:false ~inverse:true ~italic:true
         ~strikethrough:true ~underline:false);
    print_char 'B';
    (* cols 2-3: Rgb foreground, faint; a real width-two CJK grapheme (U+4E00), not an ASCII stand-in. *)
    Update.Set_style
      (full_style ~background:Style.Default
         ~foreground:(Style.Rgb (rgb ~red:200 ~green:100 ~blue:50))
         ~bold:false ~faint:true ~invisible:false ~inverse:false ~italic:false ~strikethrough:false ~underline:false);
    print_scalar 0x4e00;
    (* col 4: Indexed background, invisible (Web_canvas must suppress the glyph draw but keep the background fill). *)
    Update.Set_style
      (full_style
         ~background:(Style.Indexed (palette_index 5))
         ~foreground:Style.Default ~bold:false ~faint:false ~invisible:true ~inverse:false ~italic:false
         ~strikethrough:false ~underline:false);
    print_char 'D';
    (* col 5: back to the default pen; left blank, so the cursor rests here with a plain style. *)
    Update.Set_style
      (full_style ~background:Style.Default ~foreground:Style.Default ~bold:false ~faint:false ~invisible:false
         ~inverse:false ~italic:false ~strikethrough:false ~underline:false);
  ]

let batch =
  List.fold_left
    (fun batch update -> Update.Batch.append batch (Update.Batch.singleton update))
    Update.Batch.empty updates

let frame =
  let renderer = Renderer.initial ~lineage_id:(Foundation.Lineage_id.of_uint (uint_exn 7)) ~policy ~size in
  match Renderer.apply policy renderer batch with
  | Error e ->
      Printf.eprintf "renderer apply failed: %s\n" (Format.asprintf "%a" Renderer.pp_error (Err.Error.kind e));
      exit 1
  | Ok applied -> (
      let snapshot = Renderer.snapshot applied in
      match Frame.of_outcome ~patch:None ~snapshot with
      | Ok frame -> frame
      | Error e ->
          Printf.eprintf "of_outcome failed: %s\n" (Format.asprintf "%a" Frame.pp_error (Err.Error.kind e));
          exit 1)

let hex_of_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

let () =
  (match Frame.validate frame with
  | Ok () -> ()
  | Error e ->
      Printf.eprintf "invalid corpus frame: %s\n" (Format.asprintf "%a" Frame.pp_error (Err.Error.kind e));
      exit 1);
  let print_line result =
    match Result.map_error (fun e -> Format.asprintf "%a" Json.E.pp_error (Err.Error.kind e)) result with
    | Ok text ->
        print_string (hex_of_string text);
        print_newline ()
    | Error msg ->
        Printf.eprintf "encode error: %s\n" msg;
        exit 1
  in
  print_line (Json.encode_html_frame (Json.html_envelope_of frame));
  print_line (Json.encode_canvas_frame (Json.canvas_envelope_of frame))
