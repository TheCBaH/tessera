(* Decodes test/node_pty/traces/<name>.json content: the committed, versioned real-terminal-output fixtures
   run.js's opt-in TESSERA_NODE_PTY_WRITE_TRACES capture mode produces (see test/README.md's "Canonical
   real-terminal traces" section). Each fixture is the initial PTY geometry plus an ordered list of
   data/resize events, already coalesced at control-event boundaries by the capture side -- this module only
   decodes and validates what was committed, it does not renormalize or reorder anything.

   Deliberately takes already-read JSON text ([of_string]), not a file path: [Jsont]/[Jsont_bytesrw] work
   identically under native, js_of_ocaml, and Melange, but plain [Stdlib] file I/O (as native's own
   test/web_rendering_traces/replay.ml uses to read these files off disk) is not available under Melange. This
   keeps the module usable by test/web_bridge_equivalence's embedded-trace corpus, compiled to all three targets,
   without any backend-specific file access. *)

type event = Data of string | Resize of { columns : int; rows : int }
type t = { columns : int; rows : int; events : event list }

let invalid what = Jsont.Error.msg Jsont.Meta.none what

(* Decode-only standard base64 (RFC 4648 alphabet, '=' padding), matching Node's
   [Buffer#toString('base64')]. Padding characters are only accepted where they can actually occur
   (the trailing 1 or 2 positions of the final 4-character group); anything else -- a stray '=',
   wrong length, out-of-alphabet character -- is a decode error rather than silently-truncated or
   garbled bytes, since this is parsing committed-but-external data. *)
let base64_decode s =
  let n = String.length s in
  if n = 0 then Ok ""
  else if n mod 4 <> 0 then Error "base64: length is not a multiple of 4"
  else
    let pad = if n >= 2 && s.[n - 1] = '=' && s.[n - 2] = '=' then 2 else if s.[n - 1] = '=' then 1 else 0 in
    let value_of_char = function
      | 'A' .. 'Z' as c -> Ok (Char.code c - Char.code 'A')
      | 'a' .. 'z' as c -> Ok (Char.code c - Char.code 'a' + 26)
      | '0' .. '9' as c -> Ok (Char.code c - Char.code '0' + 52)
      | '+' -> Ok 62
      | '/' -> Ok 63
      | c -> Error (Printf.sprintf "base64: invalid character %C" c)
    in
    let last_group = (n / 4) - 1 in
    let exception Fail of string in
    try
      let buf = Buffer.create (n / 4 * 3) in
      for group = 0 to last_group do
        let value_at k =
          let c = s.[(group * 4) + k] in
          if c = '=' then (
            if not (group = last_group && k >= 4 - pad) then raise (Fail "base64: '=' outside final padding");
            0)
          else match value_of_char c with Ok v -> v | Error msg -> raise (Fail msg)
        in
        let v0 = value_at 0 and v1 = value_at 1 and v2 = value_at 2 and v3 = value_at 3 in
        Buffer.add_char buf (Char.chr ((v0 lsl 2) lor (v1 lsr 4) land 0xff));
        Buffer.add_char buf (Char.chr ((v1 lsl 4) lor (v2 lsr 2) land 0xff));
        Buffer.add_char buf (Char.chr ((v2 lsl 6) lor v3 land 0xff))
      done;
      let out = Buffer.contents buf in
      Ok (String.sub out 0 (String.length out - pad))
    with Fail msg -> Error msg

let event_obj_jsont =
  Jsont.Object.map (fun kind bytes_base64 columns rows -> (kind, bytes_base64, columns, rows))
  |> Jsont.Object.mem "kind" Jsont.string
  |> Jsont.Object.opt_mem "bytes_base64" Jsont.string
  |> Jsont.Object.opt_mem "columns" Jsont.int
  |> Jsont.Object.opt_mem "rows" Jsont.int |> Jsont.Object.finish

let event_jsont =
  Jsont.map event_obj_jsont ~dec:(function
    | "data", Some bytes_base64, None, None -> (
        match base64_decode bytes_base64 with Ok bytes -> Data bytes | Error msg -> invalid msg)
    | "resize", None, Some columns, Some rows when columns > 0 && rows > 0 -> Resize { columns; rows }
    | _ -> invalid "trace event")

let trace_obj_jsont =
  Jsont.Object.map (fun columns rows events -> (columns, rows, events))
  |> Jsont.Object.mem "columns" Jsont.int |> Jsont.Object.mem "rows" Jsont.int
  |> Jsont.Object.mem "events" (Jsont.list event_jsont)
  |> Jsont.Object.finish

let trace_jsont =
  Jsont.map trace_obj_jsont ~dec:(fun (columns, rows, events) ->
      if columns > 0 && rows > 0 then { columns; rows; events } else invalid "trace geometry")

let of_string content = Jsont_bytesrw.decode_string trace_jsont content
