(* The observer wire protocol's own contract: every {!Frame.t} kind round-trips through {!Frame.encode}/{!Frame.feed}
   regardless of how the byte stream is chunked, and each documented rejection (bad preamble, truncated payload,
   unknown frame tag) comes back as a typed {!Frame.error}, never an exception. *)
open Tessera_test_support.Support
module Frame = Tessera_proxy_protocol.Frame
module Foundation = Tessera_foundation
module Observer = Tessera_proxy_observer

let ( let* ) = Result.bind
let or_fail = function Ok value -> value | Error message -> failwith message

let feed_all frames =
  let buffer = Buffer.create 256 in
  Frame.write_preamble buffer;
  List.iter (Frame.encode buffer) frames;
  Buffer.to_bytes buffer

(* Feeds [bytes] to a fresh reader in chunks of [chunk_size], proving the parser does not depend on how the
   transport happens to split a stream. *)
let decode_chunked ?(chunk_size = 3) bytes =
  let length = Bytes.length bytes in
  let rec loop reader offset acc =
    if offset >= length then Ok (List.rev acc)
    else
      let len = min chunk_size (length - offset) in
      match Frame.feed reader bytes ~off:offset ~len with
      | Error error -> Error error
      | Ok (reader, frames) -> loop reader (offset + len) (List.rev_append frames acc)
  in
  loop (Frame.reader ()) 0 []

let pp_frames ppf frames =
  Format.fprintf ppf "[%a]" (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ") Frame.pp) frames

let%expect_test "each frame kind round-trips through encode/decode, chunked at an arbitrary boundary" =
  let size = or_fail (size 4 2) in
  let traffic =
    Frame.Traffic { sequence = 0; direction = Foundation.Types.Application_to_terminal; bytes = Bytes.of_string "hi" }
  in
  let resize =
    Frame.Resize { sequence = 1; size; pixels = Some { width = 40; height = 20; unit_ = Frame.Pixels.Css_pixels } }
  in
  let resize_no_pixels = Frame.Resize { sequence = 2; size; pixels = None } in
  let effect_frame =
    Frame.Effect
      {
        sequence = 3;
        item =
          Tessera_model.Effect.Diagnostic (Tessera_model.Effect.Invalid_utf8 { offset = Foundation.Byte_offset.zero });
      }
  in
  let gap = Frame.Gap { skipped = 5; resume = 9 } in
  let bytes = feed_all [ traffic; resize; resize_no_pixels; effect_frame; gap ] in
  let decoded = or_fail (Result.map_error (Format.asprintf "%a" Frame.pp_error) (decode_chunked bytes)) in
  Format.printf "%a@." pp_frames decoded;
  [%expect
    {| [traffic(#0, application-to-terminal, 2 byte(s)); resize(#1, 4×2, 40x20(css-pixels)); resize(#2, 4×2); effect(#3, diagnostic(invalid-utf8(offset=0))); gap(skipped=5, resume=9)] |}]

let%expect_test "an authoritative snapshot built from a real outcome round-trips" =
  let outcome =
    or_fail
      (let* policy = policy () and* size = size 3 2 and* lineage_id_uint = uint 1 in
       let lineage_id = Foundation.Lineage_id.of_uint lineage_id_uint in
       let session = Tessera.initial ~lineage_id ~policy ~size in
       let* chunk = slice "AB" in
       with_error_kind Tessera.Session.pp_error (Tessera.ingest session (Tessera.Bytes chunk)))
  in
  let policy = or_fail (policy ()) in
  let authority = Frame.Authority.make ~policy in
  let snapshot = Frame.Snapshot.of_outcome ~position:7 outcome in
  let bytes = feed_all [ Frame.Authoritative_snapshot (authority, snapshot) ] in
  let decoded = or_fail (Result.map_error (Format.asprintf "%a" Frame.pp_error) (decode_chunked ~chunk_size:5 bytes)) in
  Format.printf "%a@." pp_frames decoded;
  [%expect
    {| [snapshot(authority(xterm-256color-core; max=80×24; no-reflow); snapshot(primary; 3×2; cursor=(1,0) visible=true; title=none; position=7; 6 cell(s)))] |}]

let%expect_test "a mismatched preamble version is rejected before any frame is parsed" =
  let buffer = Buffer.create 16 in
  Foundation.Wire.write_u8 buffer 99;
  Frame.encode buffer (Frame.Gap { skipped = 1; resume = 1 });
  (match decode_chunked (Buffer.to_bytes buffer) with
  | Error error -> Format.printf "%a@." Frame.pp_error error
  | Ok _ -> Format.printf "expected an error@.");
  [%expect {| unknown protocol version 99 |}]

let%expect_test "a truncated stream yields no frames and no error -- the caller simply has not fed enough yet" =
  let bytes = feed_all [ Frame.Gap { skipped = 1; resume = 2 } ] in
  let truncated = Bytes.sub bytes 0 (Bytes.length bytes - 1) in
  let decoded = or_fail (Result.map_error (Format.asprintf "%a" Frame.pp_error) (decode_chunked truncated)) in
  Format.printf "frames=%d@." (List.length decoded);
  [%expect {| frames=0 |}]

let%expect_test "an unknown frame tag is a typed, non-raising error" =
  let buffer = Buffer.create 16 in
  Frame.write_preamble buffer;
  let body = Buffer.create 4 in
  Foundation.Wire.write_u8 body 200;
  Foundation.Wire.write_bytes buffer (Buffer.to_bytes body);
  (match decode_chunked (Buffer.to_bytes buffer) with
  | Error error -> Format.printf "%a@." Frame.pp_error error
  | Ok _ -> Format.printf "expected an error@.");
  [%expect {| unknown frame kind 200 |}]

let%expect_test "publishing observer records converts through Frame.of_record unchanged" =
  let ring = Observer.Ring.create ~capacity:4 in
  let sequence = Observer.Ring.next_sequence ring in
  let record =
    Observer.Record.traffic ~sequence ~direction:Foundation.Types.Terminal_to_application ~bytes:(Bytes.of_string "x")
  in
  Format.printf "%a@." Frame.pp (Frame.of_record record);
  [%expect {| traffic(#0, terminal-to-application, 1 byte(s)) |}]
