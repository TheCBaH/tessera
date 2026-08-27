(* milestones.md follow-on: "add a proxy envelope for observer position and description identity" on top of the
   portable Tessera.Checkpoint codec. Tessera_proxy_linux.Checkpoint is the outer envelope under test here. *)
module Foundation = Tessera_foundation
open Tessera_test_support.Support
module Record = Tessera_proxy_observer.Record
module Ring = Tessera_proxy_observer.Ring
module Checkpoint = Tessera_proxy_linux.Checkpoint

(* Both Tessera.Checkpoint and Tessera_proxy_linux.Checkpoint frame their payload identically: a version byte, then
   any number of (tag byte, length-prefixed bytes) fields, in a fixed encode order. Reused here to inspect/tamper
   with either layer without a test-only export from either module. *)
let split_fields bytes =
  let reader = Foundation.Wire.reader bytes in
  let read pp = with_error_kind pp in
  let* version = read Foundation.Wire.pp_error (Foundation.Wire.read_u8 reader) in
  let rec loop acc =
    if Foundation.Wire.at_end reader then Ok (List.rev acc)
    else
      let* tag = read Foundation.Wire.pp_error (Foundation.Wire.read_u8 reader) in
      let* payload = read Foundation.Wire.pp_error (Foundation.Wire.read_bytes reader) in
      loop ((tag, payload) :: acc)
  in
  let* fields = loop [] in
  Ok (version, fields)

let join_fields version fields =
  let buffer = Buffer.create 256 in
  Foundation.Wire.write_u8 buffer version;
  List.iter
    (fun (tag, payload) ->
      Foundation.Wire.write_u8 buffer tag;
      Foundation.Wire.write_bytes buffer payload)
    fields;
  Buffer.to_bytes buffer

let build ~columns ~rows ~text =
  let* policy = policy ~max_columns:columns ~max_rows:rows () in
  let* size = size columns rows in
  let* lineage_uint = uint 1 in
  let session = Tessera.initial ~lineage_id:(Foundation.Lineage_id.of_uint lineage_uint) ~policy ~size in
  let* slice = slice text in
  let* outcome = with_error_kind Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes slice)) in
  Ok (Tessera.session outcome)

let checkpoint_of ?(description_identity = Some "xterm-256color") ?(observer_position = 7) session =
  Checkpoint.of_session ~session ~description_identity ~observer_position:(Record.sequence_of_int observer_position)

let%expect_test
    "a restored proxy checkpoint continues identically to the original session, and reports back its own fields" =
  let result =
    let* session = build ~columns:3 ~rows:2 ~text:"AB" in
    let checkpoint = checkpoint_of ~description_identity:(Some "xterm-256color") ~observer_position:42 session in
    let* restored = with_error_kind Checkpoint.pp_error (Checkpoint.to_restored checkpoint) in
    let* second_slice = slice "C" in
    let probe = Tessera.Bytes second_slice in
    let* restored_outcome = with_error_kind Tessera.Session.pp_error (Tessera.ingest restored.session probe) in
    let* live_outcome = with_error_kind Tessera.Session.pp_error (Tessera.ingest session probe) in
    Ok
      ( Format.asprintf "%a" Tessera.pp_outcome restored_outcome = Format.asprintf "%a" Tessera.pp_outcome live_outcome,
        restored.description_identity,
        Record.sequence_to_int restored.observer_position )
  in
  let pp ppf (same, identity, position) =
    Format.fprintf ppf "same_continuation=%b identity=%a position=%d" same
      (Format.pp_print_option Format.pp_print_string)
      identity position
  in
  Format.printf "%a@." (pp_result pp) result;
  [%expect {| same_continuation=true identity=xterm-256color position=42 |}]

let%expect_test "a restored proxy checkpoint's observer position lets an already-holding client resume without a gap" =
  let result =
    let* session = build ~columns:3 ~rows:2 ~text:"AB" in
    let checkpoint = checkpoint_of ~observer_position:7 session in
    let* restored = with_error_kind Checkpoint.pp_error (Checkpoint.to_restored checkpoint) in
    let stale_cursor = Ring.cursor (Ring.create ~capacity:4 ~start_position:restored.observer_position) in
    let resumed_ring = Ring.create ~capacity:4 ~start_position:restored.observer_position in
    let published =
      Record.traffic ~sequence:(Ring.next_sequence resumed_ring) ~direction:Foundation.Types.Application_to_terminal
        ~bytes:(Bytes.of_string "post-restart")
    in
    Ring.publish resumed_ring published;
    match Ring.read resumed_ring stale_cursor with
    | Some (Ring.Record (record, _)) -> Ok (Format.asprintf "%a" Record.pp record)
    | Some (Ring.Gap _) -> Ok "unexpected gap"
    | None -> Ok "unexpected: caught up with nothing published"
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| traffic(#7, application-to-terminal, 12 byte(s)) |}]

let%expect_test "a proxy checkpoint's envelope is versioned and length-delimited" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let checkpoint = checkpoint_of session in
    let* version, fields = split_fields (Checkpoint.to_bytes checkpoint) in
    Ok (version, List.map (fun (tag, payload) -> (tag, Bytes.length payload)) fields)
  in
  let pp ppf (version, fields) =
    Format.fprintf ppf "version=%d fields=[%a]" version
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         (fun ppf (tag, len) -> Format.fprintf ppf "tag=%d,len=%d" tag len))
      fields
  in
  Format.printf "%a@." (pp_result pp) result;
  [%expect {| version=1 fields=[tag=1,len=91; tag=2,len=16; tag=3,len=1] |}]

let%expect_test "proxy checkpoint restore rejects an unknown version" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let checkpoint = checkpoint_of session in
    let* version, fields = split_fields (Checkpoint.to_bytes checkpoint) in
    let corrupted = Checkpoint.of_bytes (join_fields (version + 1) fields) in
    with_error_kind Checkpoint.pp_error (Checkpoint.to_restored corrupted)
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| unknown version 2 |}]

let%expect_test "proxy checkpoint restore rejects a truncated payload" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let checkpoint = checkpoint_of session in
    let bytes = Checkpoint.to_bytes checkpoint in
    let truncated = Bytes.sub bytes 0 (Bytes.length bytes - 1) in
    with_error_kind Checkpoint.pp_error (Checkpoint.to_restored (Checkpoint.of_bytes truncated))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| wire(truncated) |}]

let%expect_test "proxy checkpoint restore rejects a duplicate field" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let checkpoint = checkpoint_of session in
    let* version, fields = split_fields (Checkpoint.to_bytes checkpoint) in
    let duplicated = join_fields version (fields @ [ List.hd fields ]) in
    with_error_kind Checkpoint.pp_error (Checkpoint.to_restored (Checkpoint.of_bytes duplicated))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| duplicate field: session |}]

let%expect_test "proxy checkpoint restore rejects a missing field" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let checkpoint = checkpoint_of session in
    let* version, fields = split_fields (Checkpoint.to_bytes checkpoint) in
    let missing = join_fields version (List.tl fields) in
    with_error_kind Checkpoint.pp_error (Checkpoint.to_restored (Checkpoint.of_bytes missing))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| missing field: session |}]

let%expect_test "proxy checkpoint restore rejects a description identity over the bounded length" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let checkpoint = checkpoint_of ~description_identity:None session in
    let* version, fields = split_fields (Checkpoint.to_bytes checkpoint) in
    let oversized_payload =
      let buffer = Buffer.create (Checkpoint.max_description_identity_bytes + 8) in
      Foundation.Wire.write_bool buffer true;
      Foundation.Wire.write_string buffer (String.make (Checkpoint.max_description_identity_bytes + 1) 'x');
      Buffer.to_bytes buffer
    in
    let tampered =
      join_fields version
        (List.map (fun (tag, payload) -> if tag = 2 then (tag, oversized_payload) else (tag, payload)) fields)
    in
    with_error_kind Checkpoint.pp_error (Checkpoint.to_restored (Checkpoint.of_bytes tampered))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| malformed description_identity |}]

let%expect_test "proxy checkpoint restore rejects an inner checkpoint that violates its own restored policy limits" =
  let result =
    (* Same technique test/core/checkpoint.ml uses: build a session whose grid is exactly as wide as its policy
       allows, then tamper the inner Tessera.Checkpoint's own encoded policy field alone (tag=1 there) so it can no
       longer fit that grid, while leaving the outer proxy envelope's own framing untouched. *)
    let* session = build ~columns:4 ~rows:1 ~text:"AB" in
    let checkpoint = checkpoint_of session in
    let* version, fields = split_fields (Checkpoint.to_bytes checkpoint) in
    let session_tag, session_payload = List.find (fun (tag, _) -> tag = 1) fields in
    let* inner_version, inner_fields = split_fields session_payload in
    let policy_tag, policy_payload = List.hd inner_fields in
    let policy_reader = Foundation.Wire.reader policy_payload in
    let* max_columns = with_error_kind Foundation.Wire.pp_error (Foundation.Wire.read_varint policy_reader) in
    let rest_offset = Bytes.length policy_payload - Foundation.Wire.remaining policy_reader in
    let rest = Bytes.sub policy_payload rest_offset (Bytes.length policy_payload - rest_offset) in
    let tampered_policy_payload =
      let buffer = Buffer.create (Bytes.length policy_payload) in
      Foundation.Wire.write_varint buffer (max_columns - 1);
      Buffer.add_bytes buffer rest;
      Buffer.to_bytes buffer
    in
    let tampered_session_payload =
      join_fields inner_version ((policy_tag, tampered_policy_payload) :: List.tl inner_fields)
    in
    let tampered =
      join_fields version
        (List.map
           (fun (tag, payload) -> if tag = session_tag then (tag, tampered_session_payload) else (tag, payload))
           fields)
    in
    with_error_kind Checkpoint.pp_error (Checkpoint.to_restored (Checkpoint.of_bytes tampered))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| inner(renderer(policy limit exceeded: columns)) |}]
