let tests =
  List.concat
    [
      Chunking.tests;
      Ingress.tests;
      Patch_algebra.tests;
      Renderer_invariants.tests;
      Checkpoint.tests;
      Terminfo_equivalence.tests;
    ]

let () = QCheck_base_runner.run_tests_main tests
