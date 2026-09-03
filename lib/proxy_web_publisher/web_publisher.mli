(** Per-client web-rendering fan-out, the observe-only web publisher: turns each
    {!Tessera.outcome} the proxy relay already produces into at most one {!Tessera_web_rendering.Web_frame.t} Reset and
    one Delta per outcome, projected and JSON-encoded at most once per target ({!Tessera_web_rendering.Web_json}'s
    HTML/Canvas envelopes, mirroring {!Web_bridge.render} exactly), and fans that out to every attached client's own
    bounded pending queue.

    Deliberately not Lwt/Unix-aware (mirrors {!Tessera_proxy_observer.Ring} being pure while a transport wraps it with
    Lwt tasks/conditions): every operation here is synchronous and non-blocking, so the whole attach/reset/delta/
    backpressure state machine is unit-testable without a socket. The transport ({!Tessera_proxy_linux.Web_server}) owns
    the WebSocket connection, the [close]-and-reconnect [resync] protocol move, and draining each {!client}'s queue onto
    the wire -- this module never resyncs a connection itself: a resync is a connection-level close+reconnect the
    transport performs, producing a brand-new {!client} via {!attach}, not a state transition this module exposes. *)

type target = Html | Canvas
type t
type client

val create : max_pending_bytes:int -> t

val attach : t -> target:target -> client
(** A new client, starting with [needs_reset = true]. If an outcome has already been observed (via {!note_outcome}),
    immediately enqueues that target's Reset message for this outcome alone -- a build failure here is silently absorbed
    (the client simply stays [needs_reset]-pending and receives its first Reset from the next successful {!note_outcome}
    instead), since {!attach} has no error channel of its own. *)

val detach : t -> client -> unit
(** Removes the client. Idempotent. Callers must call this exactly once per {!attach}, from whichever task notices the
    connection ending, so no client record outlives its connection. *)

type error = [ `Frame of Tessera_web_rendering.Web_frame.error | `Json of Tessera_web_rendering.Web_json.error ]

module E : Err.S with type error = error

val note_outcome : t -> Tessera.outcome -> (unit, error) Err.t
(** Builds at most one neutral Reset {!Tessera_web_rendering.Web_frame.t} and one Delta per outcome, and encodes each at
    most once per target actually attached (a client on a target no one is attached to is never touched at all), shared
    across every client on that target. Per client: if [needs_reset], enqueue that target's Reset message and clear the
    flag; otherwise enqueue the Delta message unless doing so would push this client's queued bytes past
    [max_pending_bytes], in which case clear its queue, enqueue that target's Reset message for *this* outcome instead
    (never resume with a delta after a drop), and leave [needs_reset = false] (the reset just sent resolves it). A
    single Reset/Delta message is never itself truncated or rejected for being large -- the bound is on backlog, not on
    one authoritative payload, matching {!Tessera_proxy_linux.Observer_server}'s equivalent snapshot behaviour.

    Returns the first {!Tessera_web_rendering.Web_frame}/{!Tessera_web_rendering.Web_json} build failure encountered
    (should not happen against a real session), but still attempts to service every other attached client first -- a
    projection failure for one target must never stop delivery to clients on the other target, and must never perturb
    the relay or the observer socket the caller also drives; callers must log and continue. A client whose own
    projection failed keeps its prior [needs_reset]/queue state untouched, so it simply retries on the next outcome. *)

val pending_length : t -> client -> int

val take_one_pending : t -> client -> string option
(** Pops the oldest queued, ready-to-send JSON text message, decrementing the client's accounted byte count. One at a
    time (not a batch): the transport is expected to call this, hand the string to the WebSocket layer, and wait for
    that write to actually flush before calling this again -- this is what makes {!pending_length} an accurate measure
    of *actually unsent* data rather than data merely handed off to a lower layer's own unbounded buffer. *)

val client_count : t -> int
(** For diagnostics/tests only. *)

val pp_error : Format.formatter -> error -> unit
