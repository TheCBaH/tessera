let get = function Ok value -> value | Error _ -> assert false
let require condition = if not condition then failwith "runtime semantic fixture failed"
let uint value = get (Tessera.UInt.of_int value)

let policy () =
  let limits =
    get
      (Tessera.Limits.make ~max_columns:(uint 80) ~max_control_bytes:(uint 1024) ~max_csi_params:(uint 16)
         ~max_diagnostics:(uint 16) ~max_rows:(uint 24) ~max_slice_bytes:(uint 4096) ~max_snapshot_cells:(uint 1920))
  in
  Tessera.Policy.make ~limits ~profile:Tessera.Policy.Xterm_256color_core

let size () = get (Tessera.Types.Size.make ~columns:(uint 2) ~rows:(uint 1))

let slice text =
  let bytes = Bytes.of_string text in
  get (Tessera.Types.slice bytes ~off:(uint 0) ~len:(uint (Bytes.length bytes)))

let size_equal left right =
  Tessera.UInt.equal (Tessera.Types.Size.columns left) (Tessera.Types.Size.columns right)
  && Tessera.UInt.equal (Tessera.Types.Size.rows left) (Tessera.Types.Size.rows right)

let has_print_a items =
  Tessera.Effect.Item_sequence.fold_left
    (fun found -> function
      | Tessera.Effect.Update (Tessera.Update.Print graphemes) ->
          found || Tessera.Unicode.Grapheme_sequence.utf8 graphemes = "A"
      | Tessera.Effect.Observation _ | Tessera.Effect.Update _ -> found)
    false items

let has_only_resize size items =
  Tessera.Effect.Item_sequence.fold_left
    (fun result -> function
      | Tessera.Effect.Observation (Tessera.Effect.Resize value) -> result + if size_equal size value then 1 else 2
      | Tessera.Effect.Observation _ | Tessera.Effect.Update _ -> result + 2)
    0 items
  = 1

let run () =
  let policy = policy () and size = size () and lineage = Tessera.Lineage_id.of_uint (uint 1) in
  let session = Tessera.initial ~lineage_id:lineage ~policy ~size in
  let pending = get (Tessera.ingest session (Tessera.Bytes (slice "A"))) in
  let printed = get (Tessera.finish (Tessera.session pending)) in
  let cursor = Tessera.Renderer.cursor (Tessera.outcome_snapshot printed) in
  require (has_print_a (Tessera.outcome_items printed));
  require (Tessera.UInt.equal (Tessera.Types.Column.to_uint cursor.position.column) (uint 1));
  let resized = get (Tessera.ingest (Tessera.session printed) (Tessera.Out_of_band (Tessera.Resize size))) in
  require (has_only_resize size (Tessera.outcome_items resized));
  require
    (match Tessera.Patch.size (Tessera.outcome_patch resized) with
    | Tessera.Patch.Keep -> false
    | Tessera.Patch.Set value -> size_equal size value);
  require (size_equal size (Tessera.Renderer.size (Tessera.outcome_snapshot resized)));
  Format.printf "tessera-runtime-fixture=ok@."
