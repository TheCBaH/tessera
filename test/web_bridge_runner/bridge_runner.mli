(** Portable OCaml wrapper around {!Tessera_web_bridge.Web_bridge} for the browser driver/Playwright suite, mirroring
    {!Tessera_test_node_pty_bridge.Bridge}'s role but for the real web-frame bridge (a browser host gets real frame
    JSON, not a formatted debug snapshot) and serving both the ["html"] and ["canvas"] targets from one wrapper (a
    future Canvas browser target reuses this same wrapper).

    No [js_of_ocaml]/Melange-specific type appears anywhere in this signature -- every entry point takes and returns
    only [int]/[string] -- so, like {!Tessera_web_bridge.Web_bridge} itself, it compiles unchanged in [byte] (a
    js_of_ocaml host), [native] (the JSONL golden generator, no browser needed), and [melange] modes.

    There is exactly one live bridge at a time: {!create} discards any previous one, matching how a browser page mounts
    exactly one target for its whole lifetime. Every function raises [Failure] on error (an invalid target string,
    invalid geometry, or a rejected push/resize/finish); none of these are expected against the committed real-terminal
    traces or the synthetic fixture corpus this suite replays. *)

val create : target:string -> lineage_id:int -> columns:int -> rows:int -> string
(** Discard any previous live bridge and construct a fresh one for [target] (["html"] or ["canvas"]) at [columns]x[rows]
    under [lineage_id]. Bakes in the canonical bootstrap sequence: calls {!Tessera_web_bridge.Web_bridge.create} then
    *immediately* an explicit {!Tessera_web_bridge.Web_bridge.resize} to the same [columns]/[rows] (mirroring
    [test/node_pty_bridge/bridge.ml]'s own create-then-resize, and [test/web_rendering_traces/replay.ml]'s "mirrors
    Bridge.create" comment), so every caller --the native JSONL golden generator and the browser-- shares one
    implementation and cannot silently diverge on the bootstrap sequence. Returns *that resize call's frame JSON*, the
    initial [reset] frame, rather than [unit].

    Every call for what is conceptually the same session's recreation must supply a [lineage_id] strictly greater than
    every value passed before; this module does not enforce that itself (it has no memory of previous instances,
    matching {!Tessera_web_bridge.Web_bridge}'s own statelessness across separate [t] values) -- the caller that
    simulates recovery is responsible for incrementing it. Raises [Failure] on an invalid [target] string or invalid
    geometry/[lineage_id]. *)

val push : string -> string
(** Ingest one chunk of host-delivered bytes through the live bridge. Returns the resulting target-frame JSON. Raises
    [Failure] on error. *)

val resize : columns:int -> rows:int -> string
(** Apply a resize to the live bridge, distinct from and always after the one {!create} already performed -- a trace's
    own [Resize] events are replayed through this. Returns the resulting target-frame JSON. Raises [Failure] on error.
*)

val finish : unit -> string
(** Signal end of input to the live bridge. Returns the resulting target-frame JSON. Raises [Failure] on error. *)
