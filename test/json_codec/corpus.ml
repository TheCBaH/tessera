(* Canonical corpus, copied unmodified (via [copy_files#]) into upstream/ and vendored/, each
   compiling it against a different Jsont/Bytesrw implementation (real opam packages vs the
   vendored, Melange-compatible overlay). Both binaries must print byte-identical output: that is
   the whole point of this executable existing twice.

   This corpus includes a real multi-byte UTF-8 grapheme (the CJK character U+4E00, three bytes),
   not just ASCII, because jsont/bytesrw's encoded JSON bytes must be proven identical for the
   terminal text this codec actually transports. The printed line is hex-encoded rather than
   written as raw text, because Melange represents OCaml's byte-oriented [string] as a native JS
   (UTF-16) string with one JS code unit per OCaml byte -- so a byte like 0xe4 becomes the JS code
   unit U+00E4, a value outside ASCII. Melange's own stdout write (`process.stdout.write`, in its
   generated `caml_io.js`) then re-encodes that code unit as *UTF-8 text*, expanding it to two
   output bytes (0xC3 0xA4) instead of writing the original single byte back out -- confirmed by
   inspecting the generated JS and the actual bytes `node` writes for this exact input. That bug
   lives in Melange's stdout channel implementation, not in jsont/bytesrw or this corpus's own
   encoded value (which is correct and identical in memory on all three backends); hex-encoding
   the print transport removes that unrelated confound, since every hex digit is plain ASCII and
   survives Melange's stdout path unchanged, while still comparing the underlying encoded bytes
   exactly. This corpus otherwise tests the JSON codec itself: numbers, bools, arrays, objects,
   optional members, and escaping of ASCII special characters. *)

type sample = { name : string; count : int; ratio : float; active : bool; tags : string list; note : string option }

let jsont =
  Jsont.Object.map (fun name count ratio active tags note -> { name; count; ratio; active; tags; note })
  |> Jsont.Object.mem "name" Jsont.string ~enc:(fun v -> v.name)
  |> Jsont.Object.mem "count" Jsont.int ~enc:(fun v -> v.count)
  |> Jsont.Object.mem "ratio" Jsont.number ~enc:(fun v -> v.ratio)
  |> Jsont.Object.mem "active" Jsont.bool ~enc:(fun v -> v.active)
  |> Jsont.Object.mem "tags" (Jsont.list Jsont.string) ~enc:(fun v -> v.tags)
  |> Jsont.Object.opt_mem "note" Jsont.string ~enc:(fun v -> v.note)
  |> Jsont.Object.finish

let samples =
  [
    { name = "plain"; count = 0; ratio = 0.0; active = false; tags = []; note = None };
    {
      name = "tessera web-rendering";
      count = 42;
      ratio = 3.14159;
      active = true;
      tags = [ "a"; "b"; "c" ];
      note = Some "hello \"world\"";
    };
    { name = "escapes\n\t\\"; count = -7; ratio = -2.5; active = false; tags = [ "<tag>"; "&amp;" ]; note = None };
    {
      name = "\xe4\xb8\x80 (U+4E00)";
      count = 1;
      ratio = 1.0;
      active = true;
      tags = [ "\xe4\xb8\x80" ];
      note = Some "\xe4\xb8\x80";
    };
  ]

let hex_of_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents buf

let () =
  List.iter
    (fun s ->
      match Jsont_bytesrw.encode_string ~format:Jsont.Minify jsont s with
      | Ok text ->
          print_string (hex_of_string text);
          print_newline ()
      | Error msg ->
          Printf.eprintf "encode error: %s\n" msg;
          exit 1)
    samples
