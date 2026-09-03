(* Generates test/web_render_playwright/goldens/<case>-html.frames.jsonl: the ordered-frame wire-stream
   oracle for tests/web_render.spec.js's Playwright rendering tests. Replays
   each committed test/node_pty/traces/<name>.json fixture through test/web_bridge_runner's single
   canonical bootstrap sequence (lineage_id:1, matching every other native replay's fixed-lineage
   convention -- one session per case), printing *every* emitted frame JSON string, one per line, in
   order -- not just the final one, matching test/web_bridge_equivalence's own "every frame" corpus
   convention. This is a committed, explicit developer command (`make web-render-gen-goldens`), like
   `make node-pty-capture-traces`; review the diff before committing regenerated goldens. Native only:
   no browser, no PTY, no Node needed to run it. *)

module Trace_fixture = Tessera_test_trace_fixture.Trace_fixture
module Bridge_runner = Tessera_test_web_bridge_runner.Bridge_runner

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let cases =
  [
    "dialog-menu-submit";
    "whiptail-menu-cancel";
    "vt-form-edit";
    "vt-scroll-redraw";
    "vt-resize-redraw";
    "vt-shell-session";
  ]

let fail fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline s;
      exit 1)
    fmt

(* Invoked via `dune exec test/web_render_playwright/gen_goldens.exe` from the repository root (see
   the Makefile's `web-render-gen-goldens` target), so these paths are relative to the repo root. *)
let trace_path name = Filename.concat (Filename.concat (Filename.concat "test" "node_pty") "traces") (name ^ ".json")

let golden_path name =
  Filename.concat
    (Filename.concat (Filename.concat "test" "web_render_playwright") "goldens")
    (name ^ "-html.frames.jsonl")

let process name =
  let trace =
    match Trace_fixture.of_string (read_file (trace_path name)) with
    | Ok t -> t
    | Error msg -> fail "%s: trace decode failed: %s" name msg
  in
  let frames = ref [] in
  let record json = frames := json :: !frames in
  (try
     record (Bridge_runner.create ~target:"html" ~lineage_id:1 ~columns:trace.columns ~rows:trace.rows);
     List.iter
       (function
         | Trace_fixture.Data bytes -> record (Bridge_runner.push bytes)
         | Trace_fixture.Resize { columns; rows } -> record (Bridge_runner.resize ~columns ~rows))
       trace.Trace_fixture.events;
     record (Bridge_runner.finish ())
   with Failure msg -> fail "%s: bridge_runner failed: %s" name msg);
  let oc = open_out (golden_path name) in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> List.iter (fun json -> Printf.fprintf oc "%s\n" json) (List.rev !frames))

let () = List.iter process cases
