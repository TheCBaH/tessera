(* The Melange side of this suite's backend-specific Node bindings. Melange compiles a plain
   top-level [let] of [int]/[string]-typed functions directly to a CommonJS export of the same name and
   arity, so unlike [jsoo_runner.ml] this needs no explicit export call -- but it still exists as its
   own file, mirroring test/melange_smoke.ml's role next to test/js_smoke.ml, so both backends run the
   same shared bridge from a same-shaped entry point rather than one backend requiring the bridge's own
   compiled module directly. All node-pty access, scenario orchestration, and golden comparison live in
   the shared Node runner (run.js), never in this file. *)

module Bridge = Tessera_test_node_pty_bridge.Bridge

let create columns rows = Bridge.create ~columns ~rows
let push = Bridge.push
let resize columns rows = Bridge.resize ~columns ~rows
let finish = Bridge.finish
let snapshotText = Bridge.snapshot_text
