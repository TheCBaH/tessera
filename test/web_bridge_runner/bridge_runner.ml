module Bridge = Tessera_web_bridge.Web_bridge
module Foundation = Tessera_foundation

(* A generous, fixed policy, mirroring test/node_pty_bridge/bridge.ml's own for the same reason: a
   real interactive program (via replayed real-terminal traces) or a driven synthetic fixture, not an
   arbitrary configuration surface, drives what crosses this boundary. *)
let policy =
  lazy
    (let get_uint n = match Foundation.UInt.of_int n with Ok v -> v | Error _ -> failwith "invalid uint" in
     let limits =
       match
         Foundation.Limits.make ~max_columns:(get_uint 1000) ~max_control_bytes:(get_uint 65536)
           ~max_csi_params:(get_uint 64) ~max_diagnostics:(get_uint 256) ~max_rows:(get_uint 1000)
           ~max_slice_bytes:(get_uint 65536) ~max_snapshot_cells:(get_uint 1_000_000)
       with
       | Ok limits -> limits
       | Error _ -> failwith "invalid policy limits"
     in
     Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core)

let target_of_string = function
  | "html" -> Bridge.Html
  | "canvas" -> Bridge.Canvas
  | s -> failwith (Printf.sprintf "invalid target %S" s)

let describe_error error = Format.asprintf "%a" Bridge.pp_error (Err.Error.kind error)
let unwrap_json result = match result with Ok json -> json | Error error -> failwith (describe_error error)
let live : Bridge.t option ref = ref None

let create ~target ~lineage_id ~columns ~rows =
  let target = target_of_string target in
  match (Foundation.UInt.of_int lineage_id, Foundation.UInt.of_int columns, Foundation.UInt.of_int rows) with
  | Error _, _, _ | _, Error _, _ | _, _, Error _ -> failwith "invalid geometry/lineage_id"
  | Ok lineage_id, Ok columns_uint, Ok rows_uint -> (
      match Foundation.Types.Size.make ~columns:columns_uint ~rows:rows_uint with
      | Error _ -> failwith "invalid geometry"
      | Ok size ->
          let bridge =
            Bridge.create ~target
              ~lineage_id:(Foundation.Lineage_id.of_uint lineage_id)
              ~policy:(Lazy.force policy) ~size
          in
          live := Some bridge;
          (* Bakes in the canonical bootstrap sequence: an explicit initial resize to the spawn
             geometry immediately after create, matching test/node_pty_bridge/bridge.ml and
             test/web_rendering_traces/replay.ml exactly, so no caller of this module can silently
             diverge on it. *)
          unwrap_json (Bridge.resize bridge ~columns ~rows))

let with_live f = match !live with None -> failwith "bridge not created" | Some bridge -> f bridge
let push text = with_live (fun bridge -> unwrap_json (Bridge.push bridge text))
let resize ~columns ~rows = with_live (fun bridge -> unwrap_json (Bridge.resize bridge ~columns ~rows))
let finish () = with_live (fun bridge -> unwrap_json (Bridge.finish bridge))
