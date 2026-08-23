module Decoder = Tessera_decoder.Decoder
open Tessera_test_support.Support

let within_allocation_budget ~label ~maximum work =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let* _ = work () in
  let allocated = Gc.allocated_bytes () -. before in
  if allocated <= maximum then Ok label
  else Error (Format.asprintf "%s allocated %.0f bytes (budget %.0f)" label allocated maximum)

(* "History/audit bounds": once an unclosed control string exceeds max_control_bytes, the decoder
   is in discard-until-terminator, and must retain only its bounded diagnostic prefix -- never a
   growing buffer proportional to the total malformed bytes seen so far. Feeding the same bounded
   chunk repeatedly against one still-open control string, and requiring every iteration (not just
   the first) to stay within one committed budget, catches a regression that accumulates history. *)
let unclosed_control_string_budget = 1_500_000.
let iterations = 20
let chunk_bytes = 4000

let%expect_test "an unclosed oversized control string never accumulates history across repeated feeds" =
  let result =
    let* policy = policy ~max_control_bytes:64 () in
    let* opener = slice "\027]" in
    let* chunk = slice (String.make chunk_bytes 'a') in
    let* opened = with_error_kind Decoder.pp_error (Decoder.feed policy Decoder.initial opener) in
    let continuation = ref opened.continuation in
    let rec loop iteration =
      if iteration > iterations then Ok "unclosed control string never accumulates history"
      else
        let* label =
          within_allocation_budget ~label:(Printf.sprintf "iteration %d within budget" iteration)
            ~maximum:unclosed_control_string_budget (fun () ->
              let* decoded = with_error_kind Decoder.pp_error (Decoder.feed policy !continuation chunk) in
              continuation := decoded.continuation;
              Ok decoded)
        in
        ignore label;
        loop (iteration + 1)
    in
    loop 1
  in
  Format.printf "%a@." (Fmt.result ~ok:Fmt.string ~error:Format.pp_print_string) result;
  [%expect {| unclosed control string never accumulates history |}]
