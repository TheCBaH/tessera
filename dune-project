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

(package
 (name tessera_unix)
 (synopsis "Unix scheduler adapter for the Tessera portable terminal core")
 (description
  "Serialises Unix file-descriptor byte reads and validated resize requests through Tessera.Session.ingest, keeping per-direction writes ordered.")
 (license MIT)
 (depends
  tessera
  threads
  (ocaml (>= 4.14))))

(package
 (name tessera_lwt)
 (synopsis "Lwt scheduler adapter for the Tessera portable terminal core")
 (description
  "Serialises Lwt file-descriptor byte reads and validated resize requests through Tessera.Session.ingest, keeping per-direction writes ordered.")
 (license MIT)
 (depends
  tessera
  lwt
  (ocaml (>= 4.14))))

(package
 (name tessera_async)
 (synopsis "Async scheduler adapter for the Tessera portable terminal core")
 (description
  "Serialises Async reader byte reads and validated resize requests through Tessera.Session.ingest, keeping per-direction writes ordered.")
 (license MIT)
 (depends
  tessera
  async
  (ocaml (>= 4.14))))
