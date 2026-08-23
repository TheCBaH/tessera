(** JS-host scheduler adapter: serialises string byte chunks and validated resize requests through
    {!Tessera.Session.ingest}/{!Tessera.finish}. It has no PTY, signal, or DOM/Node dependency: the host (a Node
    stream's ["data"]/["close"] events, a WebSocket's [onmessage]/[onclose], an xterm.js data callback, ...) is the
    "read loop", pushing chunks and calling {!finish} on its own schedule.

    This covers both the JSOO and Melange adapters with one implementation: it is compiled in [byte] mode for
    js_of_ocaml (which builds JS from bytecode-consuming executables, so a JSOO host links this library and compiles the
    result, as {!module:Tessera_runtime_fixture.Runtime_fixture} already does for the smoke fixture) and in [melange]
    mode directly. Unlike {!module:Tessera_unix.Unix_adapter}, {!module:Tessera_lwt.Lwt_adapter}, and
    {!module:Tessera_async.Async_adapter}, there is no OS descriptor to read and no scheduler-level concurrency to guard
    with a lock: a JS host is single-threaded, and {!push}/{!resize}/ {!finish} are plain synchronous functions that
    return their outcome directly rather than delivering it through a callback, so the host's own event handler is the
    entire integration -- there is no [run] loop here to drive. *)

type t

type error =
  [ `Invalid_count of Tessera_foundation.UInt.error
  | `Invalid_value of Tessera_foundation.Types.error
  | `Session of Tessera.Session.error ]

module E : Err.S with type error = error

val create :
  lineage_id:Tessera_foundation.Lineage_id.t ->
  policy:Tessera_foundation.Policy.t ->
  size:Tessera_foundation.Types.Size.t ->
  t

val push : t -> string -> (Tessera.outcome, error) Err.t
(** Ingest one chunk of host-delivered bytes, e.g. one ["data"] event's payload. Unlike the descriptor-reading adapters,
    [text] is not drawn from a caller-owned reusable buffer: the host hands over a complete, immutable chunk each call.
*)

val resize : t -> columns:int -> rows:int -> (Tessera.outcome, error) Err.t

val finish : t -> (Tessera.outcome, error) Err.t
(** Call once, when the host's data source signals end of input (e.g. a Node stream's ["close"]/["end"] or a WebSocket's
    [onclose]). *)

val pp_error : Format.formatter -> error -> unit
