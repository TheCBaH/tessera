module Foundation = Tessera_foundation
module Model = Tessera_model
open Tessera_test_support.Support

let print_scenario (scenario : Scenario.scenario) =
  match Reference.run scenario with
  | Error message -> Format.printf "%s: ERROR %s@." scenario.name message
  | Ok { steps; _ } ->
      Format.printf "%s@." scenario.name;
      List.iter (fun step -> Format.printf "  %a@." Reference.pp_step step) steps

let%expect_test "adapter-conformance fixtures replay deterministically against the reference driver" =
  List.iter print_scenario Scenario.all;
  [%expect
    {|
    ordered ingress interleaves writes and resizes in host order
      write("AB"): [update(print([<U+0041>]))]; generation 0->1; size=keep
      resize(6x2): [observation(resize(6×2))]; generation 1->2; size=6×2
      write("CD"): [update(print([<U+0042>])); update(print([<U+0043>]))]; generation 2->3; size=keep
      resize(4x3): [observation(resize(4×3))]; generation 3->4; size=4×3
      write("EF"): [update(print([<U+0044>])); update(print([<U+0045>]))]; generation 4->5; size=keep
      eof: [update(print([<U+0046>]))]; generation 5->6; size=keep
    a short-write delivery of one logical write
      short-write(final piece "D"): [update(print([<U+0043>]))]; generation 3->4; size=keep
      eof: [update(print([<U+0044>]))]; generation 4->5; size=keep
    backpressure pauses do not affect ingested order or content
      write("AB"): [update(print([<U+0041>]))]; generation 0->1; size=keep
      backpressure-pause: (flow control only, never becomes ingress)
      backpressure-resume: (flow control only, never becomes ingress)
      write("CD"): [update(print([<U+0042>])); update(print([<U+0043>]))]; generation 1->2; size=keep
      eof: [update(print([<U+0044>]))]; generation 2->3; size=keep
    a host failure stops ingress before later events are delivered
      write("AB"): [update(print([<U+0041>]))]; generation 0->1; size=keep
      failure("read error"): ERROR adapter stopped: read error
    a resize to a distinct size
      write("AB"): [update(print([<U+0041>]))]; generation 0->1; size=keep
      resize(6x3): [observation(resize(6×3))]; generation 1->2; size=6×3
      eof: [update(print([<U+0042>]))]; generation 2->3; size=keep
    a resize to the current size
      write("AB"): [update(print([<U+0041>]))]; generation 0->1; size=keep
      resize(4x2): [observation(resize(4×2))]; generation 1->2; size=4×2
      eof: [update(print([<U+0042>]))]; generation 2->3; size=keep
    a burst of host resize notifications coalesces to the last one
      write("AB"): [update(print([<U+0041>]))]; generation 0->1; size=keep
      coalesced-resize(delivers=7x3, drops=2 earlier notification(s)): [observation(resize(7×3))]; generation 1->2; size=7×3
      write("CD"): [update(print([<U+0042>])); update(print([<U+0043>]))]; generation 2->3; size=keep
      eof: [update(print([<U+0044>]))]; generation 3->4; size=keep |}]

(* A conforming adapter may deliver one logical host write as several short pieces (e.g. because
   its read buffer is small); the final rendered content must be identical either way. *)
let%expect_test "a short-write delivery has the same final content as the same write delivered whole" =
  let result =
    let* split = Reference.run Scenario.short_writes and* whole = Reference.run Scenario.short_writes_reference in
    match (split.last_outcome, whole.last_outcome) with
    | Some split_outcome, Some whole_outcome ->
        let cells outcome =
          Format.asprintf "%a" Model.Collection.Snapshot_cells.pp
            (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome))
        in
        Ok (cells split_outcome = cells whole_outcome)
    | _ -> Error "expected both scenarios to reach eof"
  in
  Format.printf "%a@." (pp_result Fmt.bool) result;
  [%expect {| true |}]

(* "Observer gaps" and the "authoritative snapshot resynchronisation" a bounded observer channel
   will eventually implement: whatever notifications it drops in
   between, the next outcome it does receive carries a *complete* grid projection, covering the
   full current size rather than only the cells changed since some earlier notification. That is
   what makes it safe for a gappy observer to resynchronise from the latest outcome alone. *)
let%expect_test "the final outcome's snapshot is a complete projection, not a partial delta" =
  let result =
    let* run = Reference.run Scenario.ordered_ingress in
    match run.last_outcome with
    | Some outcome ->
        let snapshot_size =
          Model.Collection.Snapshot_cells.size (Tessera.Renderer.cells (Tessera.outcome_snapshot outcome))
        in
        Ok (Format.asprintf "%a" Foundation.Types.Size.pp snapshot_size)
    | None -> Error "expected at least one outcome"
  in
  Format.printf "%a@." (pp_result Format.pp_print_string) result;
  [%expect {| 4×3 |}]
