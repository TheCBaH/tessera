module Model = Tessera_model
module Decoder = Tessera.Decoder

let decode_all chunks =
  let rec loop continuation items = function
    | [] ->
        Result.map
          (fun (finished : Decoder.decoded) ->
            (Model.Effect.Item_sequence.append items finished.items, finished.continuation))
          (Decoder.finish Generators.default_policy continuation)
    | chunk :: rest -> (
        match Decoder.feed Generators.default_policy continuation (Generators.slice_exn chunk) with
        | Ok decoded -> loop decoded.continuation (Model.Effect.Item_sequence.append items decoded.items) rest
        | Error _ as error -> error)
  in
  loop Decoder.initial Model.Effect.Item_sequence.empty chunks

let arbitrary =
  QCheck.make Generators.text_with_splits_gen ~print:(fun (text, points) ->
      Printf.sprintf "text=%S points=[%s]" text (String.concat ";" (List.map string_of_int points)))

(* Design claim "Chunking does not change meaning": splitting a byte stream at arbitrary points,
   including across malformed/unterminated sequences, must never change the decoded items or the
   resulting continuation. *)
let chunk_invariance =
  QCheck.Test.make ~count:400 ~name:"decoder ingestion is invariant to arbitrary chunk boundaries" arbitrary
    (fun (text, points) ->
      match (decode_all [ text ], decode_all (Generators.chunks_of text points)) with
      | Ok (whole_items, whole_continuation), Ok (chunked_items, chunked_continuation) ->
          whole_items = chunked_items
          && Format.asprintf "%a" Decoder.pp whole_continuation = Format.asprintf "%a" Decoder.pp chunked_continuation
      | Error _, _ | _, Error _ -> QCheck.Test.fail_report "decoder feed/finish reported an error for generated input")

let byte_at_a_time =
  QCheck.Test.make ~count:200 ~name:"decoder ingestion is invariant when fed one byte at a time"
    (QCheck.make Generators.random_terminal_bytes ~print:(Printf.sprintf "%S"))
    (fun text ->
      let one_byte_chunks = List.init (String.length text) (fun index -> String.sub text index 1) in
      match (decode_all [ text ], decode_all one_byte_chunks) with
      | Ok (whole_items, whole_continuation), Ok (chunked_items, chunked_continuation) ->
          whole_items = chunked_items
          && Format.asprintf "%a" Decoder.pp whole_continuation = Format.asprintf "%a" Decoder.pp chunked_continuation
      | Error _, _ | _, Error _ -> QCheck.Test.fail_report "decoder feed/finish reported an error for generated input")

let tests = [ chunk_invariance; byte_at_a_time ]
