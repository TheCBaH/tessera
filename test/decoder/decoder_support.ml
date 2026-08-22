module Model = Tessera_model
module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support

let decode policy continuation text =
  let* slice = slice text in
  with_error_kind Decoder.pp_error (Decoder.feed policy continuation slice)

let finish policy continuation = with_error_kind Decoder.pp_error (Decoder.finish policy continuation)

let decode_chunks policy chunks =
  let rec loop continuation items = function
    | [] -> Ok (items, continuation)
    | chunk :: rest ->
        let* decoded = decode policy continuation chunk in
        loop decoded.continuation (Model.Effect.Item_sequence.append items decoded.items) rest
  in
  loop Decoder.initial Model.Effect.Item_sequence.empty chunks

let decode_to_end policy chunks =
  let* items, continuation = decode_chunks policy chunks in
  let* finished = finish policy continuation in
  Ok (Model.Effect.Item_sequence.append items finished.items, finished.continuation)

let check_decoder_splits policy text =
  let* baseline_items, _ = decode_to_end policy [ text ] in
  let length = String.length text in
  let rec loop index =
    if index > length then Ok length
    else
      let* candidate_items, _ =
        decode_to_end policy [ String.sub text 0 index; String.sub text index (length - index) ]
      in
      if candidate_items = baseline_items then loop (index + 1)
      else Error (Format.asprintf "decoder split mismatch at byte %d" index)
  in
  loop 0
