module Adapter = Tessera_js_adapter.Js_adapter

let get_uint n = match Tessera_foundation.UInt.of_int n with Ok value -> value | Error _ -> assert false

(* A generous, fixed policy: this test harness has no configuration surface, only geometry large
   enough for every scenario in this suite (including the 60x16 resize target) with
   ample headroom, mirroring lib/proxy_linux/proxy.ml's own built-in policy for the same reason -- a
   real interactive program, not a synthetic fixture, drives what crosses this boundary. *)
let policy =
  lazy
    (let limits =
       match
         Tessera_foundation.Limits.make ~max_columns:(get_uint 1000) ~max_control_bytes:(get_uint 65536)
           ~max_csi_params:(get_uint 64) ~max_diagnostics:(get_uint 256) ~max_rows:(get_uint 1000)
           ~max_slice_bytes:(get_uint 65536) ~max_snapshot_cells:(get_uint 1_000_000)
       with
       | Ok limits -> limits
       | Error _ -> assert false
     in
     Tessera_foundation.Policy.make ~limits ~profile:Tessera_foundation.Policy.Xterm_256color_core)

type live = { adapter : Adapter.t; mutable outcome : Tessera.outcome; mutable diagnostics : string list }

let live : live option ref = ref None
let describe_error error = Format.asprintf "%a" (Err.Error.pp_kind Adapter.pp_error) error

let record_diagnostics state outcome =
  Tessera.Effect.Item_sequence.fold_left
    (fun () -> function
      | Tessera.Effect.Observation (Tessera.Effect.Diagnostic diagnostic) ->
          state.diagnostics <- state.diagnostics @ [ Format.asprintf "%a" Tessera.Effect.pp_diagnostic diagnostic ]
      | Tessera.Effect.Observation (Tessera.Effect.Resize _) | Tessera.Effect.Update _ -> ())
    () (Tessera.outcome_items outcome)

let apply state result =
  match result with
  | Error error -> describe_error error
  | Ok outcome ->
      record_diagnostics state outcome;
      state.outcome <- outcome;
      ""

let with_live f = match !live with None -> "bridge not created" | Some state -> f state

let create ~columns ~rows =
  match (Tessera_foundation.UInt.of_int columns, Tessera_foundation.UInt.of_int rows) with
  | Error error, _ | _, Error error -> Format.asprintf "%a" (Err.Error.pp_kind Tessera_foundation.UInt.pp_error) error
  | Ok columns, Ok rows -> (
      match Tessera_foundation.Types.Size.make ~columns ~rows with
      | Error error -> Format.asprintf "%a" (Err.Error.pp_kind Tessera_foundation.Types.pp_error) error
      | Ok size -> (
          let lineage_id = Tessera_foundation.Lineage_id.of_uint (get_uint 1) in
          let adapter = Adapter.create ~lineage_id ~policy:(Lazy.force policy) ~size in
          match
            Adapter.resize adapter
              ~columns:(Tessera_foundation.UInt.to_int columns)
              ~rows:(Tessera_foundation.UInt.to_int rows)
          with
          | Error error -> describe_error error
          | Ok outcome ->
              let state = { adapter; outcome; diagnostics = [] } in
              record_diagnostics state outcome;
              live := Some state;
              ""))

let push text = with_live (fun state -> apply state (Adapter.push state.adapter text))
let resize ~columns ~rows = with_live (fun state -> apply state (Adapter.resize state.adapter ~columns ~rows))
let finish () = with_live (fun state -> apply state (Adapter.finish state.adapter))

let cell_char cell =
  match Tessera.Cell.contents cell with
  | Tessera.Cell.Empty -> " "
  | Tessera.Cell.Wide_continuation -> "\xc2\xb7" (* U+00B7 MIDDLE DOT *)
  | Tessera.Cell.Glyph grapheme -> Tessera.Unicode.utf8 grapheme

let row_text cells ~columns ~row =
  let buffer = Buffer.create columns in
  for column = 0 to columns - 1 do
    let coord =
      Tessera_foundation.Types.coord
        ~column:(Tessera_foundation.Types.Column.of_uint (get_uint column))
        ~row:(Tessera_foundation.Types.Row.of_uint (get_uint row))
    in
    Buffer.add_string buffer (cell_char (Tessera.Collection.Snapshot_cells.get cells coord))
  done;
  Buffer.contents buffer

let snapshot_text () =
  with_live (fun state ->
      let snapshot = Tessera.outcome_snapshot state.outcome in
      let size = Tessera.Renderer.size snapshot in
      let columns = Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Size.columns size) in
      let rows = Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Size.rows size) in
      let cells = Tessera.Renderer.cells snapshot in
      let cursor : Tessera.Renderer.cursor = Tessera.Renderer.cursor snapshot in
      let active =
        match Tessera.Renderer.active snapshot with
        | Tessera_foundation.Types.Primary -> "primary"
        | Tessera_foundation.Types.Alternate -> "alternate"
      in
      let title = match Tessera.Renderer.title snapshot with None -> "none" | Some title -> title in
      let buffer = Buffer.create ((columns + 1) * (rows + 1)) in
      Buffer.add_string buffer
        (Format.asprintf "size=%dx%d active=%s cursor=%d,%d visible=%b title=%s" columns rows active
           (Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Column.to_uint cursor.position.column))
           (Tessera_foundation.UInt.to_int (Tessera_foundation.Types.Row.to_uint cursor.position.row))
           (Tessera.Renderer.cursor_visible snapshot)
           title);
      for row = 0 to rows - 1 do
        Buffer.add_char buffer '\n';
        Buffer.add_string buffer (row_text cells ~columns ~row)
      done;
      List.iter
        (fun diagnostic ->
          Buffer.add_char buffer '\n';
          Buffer.add_string buffer "diag:";
          Buffer.add_string buffer diagnostic)
        state.diagnostics;
      Buffer.contents buffer)
