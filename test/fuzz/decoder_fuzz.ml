module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support

(* Deliberately small so that budget-exhaustion and discard-until-terminator states -- not just the
   common case -- are reached on most iterations, per the design's "small policy limits". *)
let small_policy =
  match policy ~max_control_bytes:32 ~max_csi_params:4 ~max_diagnostics:4 ~max_snapshot_cells:64 () with
  | Ok value -> value
  | Error message -> failwith message

(* Crash-freedom, not correctness, is what these targets check: an [Error] is an entirely acceptable
   outcome for adversarial bytes, an uncaught exception is not. Crowbar treats any exception escaping
   the test function as a failure, so no explicit assertion is needed beyond exhausting the match. *)
let feed_all chunks =
  let rec loop continuation = function
    | [] -> Decoder.finish small_policy continuation
    | chunk :: rest -> (
        match slice chunk with
        | Error message -> invalid_arg message
        | Ok chunk_slice -> (
            match Decoder.feed small_policy continuation chunk_slice with
            | Ok decoded -> loop decoded.continuation rest
            | Error _ as error -> error))
  in
  loop Decoder.initial chunks

let () =
  Crowbar.add_test ~name:"decoder never raises on a single arbitrary byte chunk" [ Crowbar.bytes ] (fun text ->
      match feed_all [ text ] with Ok _ | Error _ -> ())

let () =
  Crowbar.add_test ~name:"decoder never raises across arbitrary chunk boundaries"
    [ Crowbar.list Crowbar.bytes ]
    (fun chunks -> match feed_all chunks with Ok _ | Error _ -> ())

(* Biases generation toward escape/CSI/OSC/DCS introducers interleaved with arbitrary bytes, so long
   malformed control strings routinely exceed [max_control_bytes] and drive the decoder into its
   bounded-diagnostic and discard-until-terminator states, rather than only ever seeing plain text. *)
let control_fragment_gen =
  Crowbar.choose
    [
      Crowbar.const "\027[";
      Crowbar.const "\027]";
      Crowbar.const "\027P";
      Crowbar.const "\027^";
      Crowbar.const "\027_";
      Crowbar.const "\027\\";
      Crowbar.bytes_fixed 1;
    ]

let () =
  Crowbar.add_test ~name:"decoder never raises on oversized malformed control strings"
    [ Crowbar.list control_fragment_gen ]
    (fun fragments -> match feed_all [ String.concat "" fragments ] with Ok _ | Error _ -> ())
