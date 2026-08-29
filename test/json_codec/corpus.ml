(* Canonical corpus, copied unmodified (via [copy_files#]) into upstream/ and vendored/, each
   compiling it against a different Jsont/Bytesrw implementation (real opam packages vs the
   vendored, Melange-compatible overlay). Both binaries must print byte-identical output: that is
   the whole point of this executable existing twice.

   ASCII-only content on purpose: Melange represents OCaml's byte-oriented [string] as a native JS
   (UTF-16) string, one JS code unit per OCaml byte, so a raw multi-byte UTF-8 sequence built as an
   OCaml string round-trips through Melange faithfully as *data* but is not printable as the
   intended Unicode text without an explicit conversion -- a pre-existing Melange/JS-string-model
   characteristic, unrelated to jsont/bytesrw's own (fully correct) JSON structural encoding, and
   squarely the JS bridge's concern (web-rendering.md step 4, out of scope here). This corpus tests
   the JSON codec itself: numbers, bools, arrays, objects, optional members, and escaping of ASCII
   special characters. *)

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
  ]

let () =
  List.iter
    (fun s ->
      match Jsont_bytesrw.encode_string ~format:Jsont.Minify jsont s with
      | Ok text ->
          print_string text;
          print_newline ()
      | Error msg ->
          Printf.eprintf "encode error: %s\n" msg;
          exit 1)
    samples
