(* The js_of_ocaml side of this suite's backend-specific browser bindings: exports
   test/web_bridge_runner/bridge_runner.ml's four entry points under global names, mirroring
   test/node_pty/jsoo_runner.ml exactly. All browser mounting, driver wiring, and trace/fixture
   orchestration live in pages/index.html and the Playwright specs, never in this file. *)

let () =
  Js_of_ocaml.Js.export "create" (fun target lineage_id columns rows ->
      Tessera_test_web_bridge_runner.Bridge_runner.create ~target ~lineage_id ~columns ~rows);
  Js_of_ocaml.Js.export "push" Tessera_test_web_bridge_runner.Bridge_runner.push;
  Js_of_ocaml.Js.export "resize" (fun columns rows ->
      Tessera_test_web_bridge_runner.Bridge_runner.resize ~columns ~rows);
  Js_of_ocaml.Js.export "finish" Tessera_test_web_bridge_runner.Bridge_runner.finish
