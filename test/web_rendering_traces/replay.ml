(* Replays each committed test/node_pty/traces/<name>.json fixture through the normal OCaml session
   (Tessera_js_adapter.Js_adapter, the same push/resize/finish surface the JSOO/Melange bridge that
   captured the trace actually used) and writes the resulting final-state HTML/Canvas target-frame
   JSON to <name>.out, for the runtest rule below to diff against goldens/<name>.out. No PTY, no
   Node, no js_of_ocaml/Melange runtime is needed here: this is what proves the web-rendering
   projection against real dialog/whiptail/shell output even when neither compiled JS backend is
   built. *)
module Foundation = Tessera_foundation
module Frame = Tessera_web_rendering.Web_frame
module Json = Tessera_web_rendering.Web_json
module Adapter = Tessera_js_adapter.Js_adapter
module Trace_fixture = Tessera_test_trace_fixture.Trace_fixture
open Tessera_test_support.Support

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let cases =
  [
    "dialog-menu-submit";
    "whiptail-menu-cancel";
    "vt-form-edit";
    "vt-scroll-redraw";
    "vt-resize-redraw";
    "vt-shell-session";
  ]

let fail fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline s;
      exit 1)
    fmt

let unwrap = function Ok v -> v | Error msg -> fail "%s" msg

(* A fixed, generous xterm-256color policy: mirrors test/node_pty_bridge/bridge.ml's own policy
   exactly, since these traces were captured against a Bridge built with those same limits. A real
   interactive program, not a synthetic fixture, drives what crosses this boundary. *)
let policy () =
  let* limits =
    let* max_columns = uint 1000
    and* max_control_bytes = uint 65536
    and* max_csi_params = uint 64
    and* max_diagnostics = uint 256
    and* max_rows = uint 1000
    and* max_slice_bytes = uint 65536
    and* max_snapshot_cells = uint 1_000_000 in
    with_error_kind Foundation.Limits.pp_error
      (Foundation.Limits.make ~max_columns ~max_control_bytes ~max_csi_params ~max_diagnostics ~max_rows
         ~max_slice_bytes ~max_snapshot_cells)
  in
  Ok (Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)

let replay (trace : Trace_fixture.t) =
  let result =
    let* policy = policy () and* initial_size = size trace.columns trace.rows and* lineage_id = uint 1 in
    let adapter = Adapter.create ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id) ~policy ~size:initial_size in
    (* Mirrors Bridge.create: an explicit initial resize to the spawn geometry, not just [create]'s
       own [~size], matching exactly what produced the committed golden snapshots these traces
       replay against. *)
    let* first = with_error_kind Adapter.pp_error (Adapter.resize adapter ~columns:trace.columns ~rows:trace.rows) in
    let* (_ : Tessera.outcome) =
      List.fold_left
        (fun acc event ->
          let* _ = acc in
          match event with
          | Trace_fixture.Data bytes -> with_error_kind Adapter.pp_error (Adapter.push adapter bytes)
          | Trace_fixture.Resize { columns; rows } ->
              with_error_kind Adapter.pp_error (Adapter.resize adapter ~columns ~rows))
        (Ok first) trace.events
    in
    with_error_kind Adapter.pp_error (Adapter.finish adapter)
  in
  unwrap result

let frame_of_outcome outcome =
  let snapshot = Tessera.outcome_snapshot outcome in
  unwrap (with_error_kind Frame.pp_error (Frame.of_outcome ~patch:None ~snapshot))

let encode_json name envelope encode =
  match with_error_kind Json.E.pp_error (encode envelope) with Ok json -> json | Error msg -> fail "%s: %s" name msg

let process name =
  let path =
    Filename.concat (Filename.concat (Filename.concat Filename.parent_dir_name "node_pty") "traces") (name ^ ".json")
  in
  let trace = unwrap (Trace_fixture.of_string (read_file path)) in
  let outcome = replay trace in
  let frame = frame_of_outcome outcome in
  let html_json = encode_json name (Json.html_envelope_of frame) Json.encode_html_frame in
  let canvas_json = encode_json name (Json.canvas_envelope_of frame) Json.encode_canvas_frame in
  let oc = open_out (name ^ ".out") in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> Printf.fprintf oc "html:%s\ncanvas:%s\n" html_json canvas_json)

let () = List.iter process cases
