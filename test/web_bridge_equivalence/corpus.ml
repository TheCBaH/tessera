(* Native/js_of_ocaml/Melange equivalence check for lib/web_bridge: replays each of the six
   embedded, committed real-terminal traces
   (embedded_traces.ml, sourced from test/node_pty/traces/*.json) through
   Tessera_web_bridge.Web_bridge, for both the HTML and Canvas targets, and prints the resulting
   canonical JSON to stdout in a fixed, deterministic order. dune compiles this single source
   natively, to js_of_ocaml, and to Melange, executes all three with plain `node` (no npm, no
   node-pty, no browser), and diffs their stdout byte-for-byte against the native run -- proving a
   compiler/runtime difference in the bridge itself, independent of test/web_rendering_traces (which
   reads the trace files off disk natively and checks a different property: that the final projected
   state matches the real captured terminal output). *)
module Foundation = Tessera_foundation
module Bridge = Tessera_web_bridge.Web_bridge
module Trace_fixture = Tessera_test_trace_fixture.Trace_fixture

let ( let* ) = Result.bind
let must_uint n = match Foundation.UInt.of_int n with Ok v -> v | Error _ -> assert false

let policy =
  lazy
    (let limits =
       match
         Foundation.Limits.make ~max_columns:(must_uint 1000) ~max_control_bytes:(must_uint 65536)
           ~max_csi_params:(must_uint 64) ~max_diagnostics:(must_uint 256) ~max_rows:(must_uint 1000)
           ~max_slice_bytes:(must_uint 65536) ~max_snapshot_cells:(must_uint 1_000_000)
       with
       | Ok limits -> limits
       | Error _ -> assert false
     in
     Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)

let size_of columns rows =
  match (Foundation.UInt.of_int columns, Foundation.UInt.of_int rows) with
  | Ok columns, Ok rows -> ( match Foundation.Types.Size.make ~columns ~rows with Ok s -> s | Error _ -> assert false)
  | _ -> assert false

let fail msg =
  print_string ("error: " ^ msg ^ "\n");
  exit 1

let unwrap = function Ok v -> v | Error msg -> fail msg
let describe error = Format.asprintf "%a" Bridge.pp_error (Err.Error.kind error)
let wrap result = Result.map_error describe result

(* Every frame the session emits, in order, not just the last: [finish] alone typically carries no
   further damage (it is an EOF signal, not new terminal output), so comparing only the final frame
   would mostly compare near-empty cursor-only deltas and miss the actual, content-bearing reset/delta
   frames the earlier resize/push calls produced. *)
let replay (trace : Trace_fixture.t) target =
  let lineage_id = Foundation.Lineage_id.of_uint (must_uint 1) in
  let size = size_of trace.columns trace.rows in
  let bridge = Bridge.create ~target ~lineage_id ~policy:(Lazy.force policy) ~size in
  let* first = wrap (Bridge.resize bridge ~columns:trace.columns ~rows:trace.rows) in
  let* rest =
    List.fold_left
      (fun acc event ->
        let* acc = acc in
        let* json =
          match event with
          | Trace_fixture.Data bytes -> wrap (Bridge.push bridge bytes)
          | Trace_fixture.Resize { columns; rows } -> wrap (Bridge.resize bridge ~columns ~rows)
        in
        Ok (json :: acc))
      (Ok []) trace.events
  in
  let* last = wrap (Bridge.finish bridge) in
  Ok ((first :: List.rev rest) @ [ last ])

let process (name, content) =
  let trace = unwrap (Trace_fixture.of_string content) in
  let html_frames = unwrap (replay trace Bridge.Html) in
  let canvas_frames = unwrap (replay trace Bridge.Canvas) in
  Printf.printf "%s\n" name;
  List.iteri (fun i json -> Printf.printf "html[%d]:%s\n" i json) html_frames;
  List.iteri (fun i json -> Printf.printf "canvas[%d]:%s\n" i json) canvas_frames

let () = List.iter process Embedded_traces.cases
