(** The JS-host web-rendering bridge: the single, intentionally thin entry point a browser/Node host drives. Each of
    {!push}/{!resize}/{!finish} does the whole pipeline in one call --
    {!Tessera_js_adapter.Js_adapter.push}/[resize]/[finish], {!Tessera_web_rendering.Web_frame.of_outcome}, then a
    {!target}-selected {!Tessera_web_rendering.Web_html}/{!Tessera_web_rendering.Web_canvas} projection encoded to
    canonical JSON via {!Tessera_web_rendering.Web_json} -- and returns that JSON string directly. It never walks cells,
    coalesces runs, calculates damage, resolves wide cells, or produces HTML/Canvas instructions itself: all of that
    stays inside the pure projection library this only calls.

    Like {!Tessera_js_adapter.Js_adapter}, this has no [js_of_ocaml]/Melange-specific type anywhere in its signature, so
    it compiles unchanged in [byte] (consumed by a JSOO host) and [melange] modes: a JS-facing export shim (mirroring
    [test/node_pty/jsoo_runner.ml]/[melange_runner.ml]) is the only backend-specific code a real browser integration
    needs to add on top of this. *)

type t

(** Fixed for a [t]'s whole lifetime, matching how a browser page mounts exactly one
    {{!module:Tessera_web_rendering.Web_html}HTML} or {{!module:Tessera_web_rendering.Web_canvas}Canvas} target -- there
    is no per-call target switch. *)
type target = Html | Canvas

type error =
  [ `Adapter of Tessera_js_adapter.Js_adapter.error
  | `Frame of Tessera_web_rendering.Web_frame.error
  | `Json of Tessera_web_rendering.Web_json.error ]

module E : Err.S with type error = error

val create :
  target:target ->
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  t

val push : t -> string -> (string, error) Err.t
(** Ingest one chunk of host-delivered bytes and return the resulting target-frame JSON. The very first frame any [t]
    ever emits (across [push]/[resize]/[finish]) is always a [reset] ({!Tessera_web_rendering.Web_frame.of_outcome}'s
    [patch:None]); every later frame is a [delta] built from the outcome's own patch, which
    {!Tessera_web_rendering.Web_frame.of_outcome} itself upgrades to a full [reset] on a resize or active-screen switch.
*)

val resize : t -> columns:int -> rows:int -> (string, error) Err.t
val finish : t -> (string, error) Err.t
val pp_error : Format.formatter -> error -> unit
