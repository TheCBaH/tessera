(* The Melange side of this suite's backend-specific browser bindings, compiled to real ES modules
   ((module_systems (esm .mjs)) -- see dune) rather than CommonJS: a plain top-level [let] of
   [int]/[string]-typed functions compiles directly to a named ES export, so pages/index.html loads
   this via a dynamic `import('/melange/melange_bridge.mjs')`, no bundler or shim needed. Mirrors
   test/node_pty/melange_runner.ml's role next to jsoo_bridge.ml. All browser mounting, driver wiring,
   and trace/fixture orchestration live in pages/index.html and the Playwright specs, never in this
   file. *)

module Bridge_runner = Tessera_test_web_bridge_runner.Bridge_runner

let create target lineage_id columns rows = Bridge_runner.create ~target ~lineage_id ~columns ~rows
let push = Bridge_runner.push
let resize columns rows = Bridge_runner.resize ~columns ~rows
let finish = Bridge_runner.finish
