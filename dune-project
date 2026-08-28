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

(package
 (name tessera_proxy_platform)
 (synopsis "Linux PTY/signal platform boundary for the Tessera proxy")
 (description
  "A module type S auditing openpty/ioctl/signalfd access, plus its real Linux binding, so the resize protocol and relay loop can be tested against a fake implementation.")
 (license MIT)
 (depends
  tessera
  (ocaml (>= 4.14))))

(package
 (name tessera_proxy_observer)
 (synopsis "Bounded observer delivery for the Tessera proxy")
 (description
  "In-process traffic/resize/effect record log with bounded, non-blocking publish, gap reporting, and authoritative snapshot resynchronisation.")
 (license MIT)
 (depends
  tessera
  (ocaml (>= 4.14))))

(package
 (name tessera_proxy_protocol)
 (synopsis "Versioned observer wire protocol for the Tessera proxy")
 (description
  "A length-delimited codec for the proxy's traffic/resize/effect records, authoritative snapshot, and gap notification, independent of any transport.")
 (license MIT)
 (depends
  tessera
  tessera_proxy_observer
  (ocaml (>= 4.14))))

(package
 (name tessera_proxy_linux)
 (synopsis "Linux terminal proxy composition root for Tessera")
 (description
  "Wires Tessera_unix.Unix_adapter, Tessera_proxy_platform, Tessera_proxy_observer, and Tessera_proxy_protocol's socket server into a proxy session and the tessera-proxy executable.")
 (license MIT)
 (depends
  tessera
  tessera_unix
  tessera_proxy_platform
  tessera_proxy_observer
  tessera_proxy_protocol
  (ocaml (>= 4.14))))
