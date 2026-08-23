(lang dune 3.10)
(using melange 0.1)
(name tessera)
(generate_opam_files true)

(package
 (name tessera)
 (synopsis "A portable pure terminal core")
 (description "Tessera decodes terminal output into an immutable logical screen.")
 (license MIT)
 (depends
  err_trace
  (ppx_expect :with-test)
  (js_of_ocaml :with-test)
  (melange :with-test)
  (qcheck-core :with-test)
  (crowbar :with-test)
  (memtrace :with-test)
  (ocaml (>= 4.14))))
