(* The js_of_ocaml side of this suite's backend-specific Node bindings: exports
   test/node_pty_bridge/bridge.ml's five entry points under [module.exports], with the argument/return
   shapes ([int]/[string]) js_of_ocaml already represents as plain JS numbers and strings, so no further
   marshalling is needed here. All node-pty access, scenario orchestration, and golden comparison live
   in the shared Node runner (run.js), never in this file. *)

let () =
  Js_of_ocaml.Js.export "create" (fun columns rows -> Tessera_test_node_pty_bridge.Bridge.create ~columns ~rows);
  Js_of_ocaml.Js.export "push" Tessera_test_node_pty_bridge.Bridge.push;
  Js_of_ocaml.Js.export "resize" (fun columns rows -> Tessera_test_node_pty_bridge.Bridge.resize ~columns ~rows);
  Js_of_ocaml.Js.export "finish" Tessera_test_node_pty_bridge.Bridge.finish;
  Js_of_ocaml.Js.export "snapshotText" Tessera_test_node_pty_bridge.Bridge.snapshot_text
