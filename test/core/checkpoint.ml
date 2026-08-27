module Foundation = Tessera_foundation
module Model = Tessera_model
open Tessera_test_support.Support

(* [Tessera.Checkpoint.of_session] always writes its three fields in this fixed order (see
   lib/core/checkpoint.ml); several tests below splice the raw envelope and rely on that order to target one
   field without needing any test-only export of the internal tag numbers. *)
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

let checkpoint_bytes session = Tessera.Checkpoint.(to_bytes (of_session session))

let restore_and_probe session probe =
  let checkpoint = Tessera.Checkpoint.of_session session in
  let* restored = with_error_kind Tessera.Checkpoint.pp_error (Tessera.Checkpoint.to_session checkpoint) in
  let* outcome = with_error_kind Tessera.Session.pp_error (Tessera.ingest restored probe) in
  Ok (Format.asprintf "%a" Tessera.pp_outcome outcome)

let%expect_test "a restored checkpoint continues identically to the original session" =
  let result =
    let* session = build ~columns:3 ~rows:2 ~text:"AB" in
    let* second_slice = slice "C" in
    let probe = Tessera.Bytes second_slice in
    let* restored_result = restore_and_probe session probe in
    let* live_outcome = with_error_kind Tessera.Session.pp_error (Tessera.ingest session probe) in
    Ok (restored_result = Format.asprintf "%a" Tessera.pp_outcome live_outcome)
  in
  Format.printf "%a@." (pp_result Fmt.bool) result;
  [%expect {| true |}]

let%expect_test "checkpoint bytes are versioned and length-delimited" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let bytes = checkpoint_bytes session in
    let* version, fields = split_fields bytes in
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
  [%expect {| version=1 fields=[tag=1,len=11; tag=2,len=7; tag=3,len=66] |}]

let%expect_test "checkpoint restore rejects an unknown version" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let bytes = checkpoint_bytes session in
    let* version, fields = split_fields bytes in
    let corrupted = Tessera.Checkpoint.of_bytes (join_fields (version + 1) fields) in
    with_error_kind Tessera.Checkpoint.pp_error (Tessera.Checkpoint.to_session corrupted)
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| unknown version 2 |}]

let%expect_test "checkpoint restore rejects a truncated payload" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let bytes = checkpoint_bytes session in
    let truncated = Bytes.sub bytes 0 (Bytes.length bytes - 1) in
    with_error_kind Tessera.Checkpoint.pp_error (Tessera.Checkpoint.to_session (Tessera.Checkpoint.of_bytes truncated))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| wire(truncated) |}]

let%expect_test "checkpoint restore rejects a duplicate field" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let bytes = checkpoint_bytes session in
    let* version, fields = split_fields bytes in
    let duplicated = join_fields version (fields @ [ List.hd fields ]) in
    with_error_kind Tessera.Checkpoint.pp_error (Tessera.Checkpoint.to_session (Tessera.Checkpoint.of_bytes duplicated))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| duplicate field: policy |}]

let%expect_test "checkpoint restore rejects a missing field" =
  let result =
    let* session = build ~columns:2 ~rows:1 ~text:"A" in
    let bytes = checkpoint_bytes session in
    let* version, fields = split_fields bytes in
    let missing = join_fields version (List.tl fields) in
    with_error_kind Tessera.Checkpoint.pp_error (Tessera.Checkpoint.to_session (Tessera.Checkpoint.of_bytes missing))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| missing field: policy |}]

let%expect_test "checkpoint restore rejects a payload exceeding its own restored policy limits" =
  let result =
    (* Build a session whose grid is exactly as wide as the policy allows (4 columns), then tamper with the
       encoded policy field alone so its declared [max_columns] can no longer fit that grid. Everything else in
       the payload -- the renderer state bytes included -- stays untouched. *)
    let* session = build ~columns:4 ~rows:1 ~text:"AB" in
    let bytes = checkpoint_bytes session in
    let* version, fields = split_fields bytes in
    let policy_tag, policy_payload = List.hd fields in
    let policy_reader = Foundation.Wire.reader policy_payload in
    let* max_columns = with_error_kind Foundation.Wire.pp_error (Foundation.Wire.read_varint policy_reader) in
    let rest_offset = Bytes.length policy_payload - Foundation.Wire.remaining policy_reader in
    let rest = Bytes.sub policy_payload rest_offset (Bytes.length policy_payload - rest_offset) in
    let tampered_payload =
      let buffer = Buffer.create (Bytes.length policy_payload) in
      Foundation.Wire.write_varint buffer (max_columns - 1);
      Buffer.add_bytes buffer rest;
      Buffer.to_bytes buffer
    in
    let tampered = join_fields version ((policy_tag, tampered_payload) :: List.tl fields) in
    with_error_kind Tessera.Checkpoint.pp_error (Tessera.Checkpoint.to_session (Tessera.Checkpoint.of_bytes tampered))
  in
  Format.printf "%a@." (pp_result (fun ppf _ -> Format.pp_print_string ppf "ok")) result;
  [%expect {| renderer(policy limit exceeded: columns) |}]
