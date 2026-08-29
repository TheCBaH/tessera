(** Shared, portable OCaml test bridge for the Node-pty integration tests. Owns construction of a
    {!Tessera_js_adapter.Js_adapter.t} with a fixed, generous xterm-256color policy, the push/resize/finish calls, and a
    stable, readable rendering of the latest logical screen that a Node test runner can compare against a committed
    golden.

    This module has no [js_of_ocaml] or Melange dependency and no [Js.t]/Node type anywhere in its signature: every
    entry point takes and returns only [int]/[string], so it compiles unchanged for both backends ([byte], consumed by a
    js_of_ocaml host exactly as {!module:Tessera_runtime_fixture.Runtime_fixture} already is, and [melange] directly).
    The only backend-specific code is the thin export shim each backend adds around it -- see
    [test/node_pty/jsoo_runner.ml] and [test/node_pty/melange_runner.ml].

    There is exactly one live adapter at a time, matching how the Node runner drives one scenario (one PTY, one adapter)
    to completion before starting the next. *)

val create : columns:int -> rows:int -> string
(** Discard any previous live adapter and construct a fresh one at [columns]x[rows], clearing accumulated diagnostics.
    Returns [""] on success, or a description of what made [columns]/[rows] or the resulting policy invalid. Must be
    called before any other function in this module. *)

val push : string -> string
(** Ingest one chunk of host-delivered bytes, e.g. one node-pty [onData] event's payload. Returns [""] on success, or a
    description of the ingest failure. *)

val resize : columns:int -> rows:int -> string
(** Apply a resize to the live adapter, mirroring a [node-pty] [resize] call. Returns [""] on success, or a description
    of the failure. *)

val finish : unit -> string
(** Signal end of input to the live adapter, as a [node-pty] [onExit] event does. Returns [""] on success, or a
    description of the failure. Idempotent calls after the first are rejected by the underlying session, like any other
    repeated {!Tessera.finish}. *)

val snapshot_text : unit -> string
(** A stable, readable rendering of the live adapter's latest logical screen, suitable for a golden-file comparison and
    for readiness polling (searching it for expected text):

    {[
      size=40x10 active=primary cursor=12,0 visible=true title=none
      Dialog menu
      ...
    ]}

    followed by exactly [rows] lines of exactly [columns] characters each, then one [diag:...] line per diagnostic
    observed since {!create}. Every grid cell contributes exactly one character: a space for an empty cell, U+00B7
    (middle dot) for a wide glyph's continuation cell, and the glyph's own UTF-8 text otherwise -- so trailing blanks
    and wide cells stay unambiguous even though every row is always exactly [columns] characters wide. *)
