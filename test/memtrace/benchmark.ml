(* Native release benchmark workload for manual allocation profiling: run with
   MEMTRACE=trace.ctf dune exec test/memtrace/benchmark.exe to capture a trace covering the same
   operation categories committed as allocation budgets in test/renderer/allocation.ml and
   test/decoder/allocation.ml -- a printable run, local edits, scroll, resize refresh, an
   alternate-screen switch, and snapshot creation -- repeated so the trace has enough samples to
   inspect for regressions such as an unexpected full-grid copy on a local edit. *)
module Foundation = Tessera_foundation
module Model = Tessera_model
module Renderer = Tessera_renderer
open Tessera_test_support.Support

let fail_on_error label = function Ok value -> value | Error message -> failwith (label ^ ": " ^ message)

let apply policy renderer batch =
  with_error_kind Renderer.Renderer.pp_error (Renderer.Renderer.apply policy renderer batch)

let print scalar =
  Model.Update.Print
    (Model.Unicode.Grapheme_sequence.singleton (Model.Unicode.grapheme_of_scalar (Uchar.of_int scalar)))

let columns = 80
let rows = 24
let run_length = 80

let iterations =
  match Sys.getenv_opt "TESSERA_MEMTRACE_ITERATIONS" with Some value -> int_of_string value | None -> 2_000

let () =
  Memtrace.trace_if_requested ~context:"tessera-renderer-benchmark" ();
  let policy = fail_on_error "policy" (policy ()) in
  let size = fail_on_error "size" (size columns rows) in
  let lineage_id = Foundation.Lineage_id.of_uint (fail_on_error "lineage" (uint 1)) in
  let printable_run = batch_of_updates (List.init run_length (fun index -> print (0x41 + (index mod 26)))) in
  let delete_one = Model.Update.Edit (Model.Update.Delete_chars (fail_on_error "delete count" (uint 1))) in
  let scroll_one = Model.Update.Scroll_up (fail_on_error "scroll count" (uint 1)) in
  let resize_refresh = Model.Update.Resize size in
  let enter_alternate = Model.Update.Alternate_screen `Enter_1049 in
  let leave_alternate = Model.Update.Alternate_screen `Leave_1049 in
  let renderer = ref (Renderer.Renderer.initial ~lineage_id ~policy ~size) in
  let step batch = renderer := Renderer.Renderer.state (fail_on_error "apply" (apply policy !renderer batch)) in
  for _ = 1 to iterations do
    step printable_run;
    step (Model.Update.Batch.singleton delete_one);
    step (Model.Update.Batch.singleton scroll_one);
    step (Model.Update.Batch.singleton resize_refresh);
    step (Model.Update.Batch.singleton enter_alternate);
    let applied = fail_on_error "apply" (apply policy !renderer (Model.Update.Batch.singleton (print 0x5a))) in
    ignore (Renderer.Renderer.cells (Renderer.Renderer.snapshot applied));
    renderer := Renderer.Renderer.state applied;
    step (Model.Update.Batch.singleton leave_alternate)
  done
