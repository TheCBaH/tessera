(lang dune 3.10)
(name tessera)
(generate_opam_files true)

(package
 (name tessera)
 (synopsis "A portable pure terminal core")
 (description "Tessera decodes terminal output into an immutable logical screen.")
 (license MIT)
 (depends
  err_trace
  (ocaml (>= 4.14))))
