(** A local, loopback-only WebSocket server exposing {!Tessera_proxy_web_publisher.Web_publisher} to a browser, over the
    [tessera.proxy-web] control channel ({!Tessera_proxy_web_protocol.Control}) and [tessera.web-frame] payload stream.
    Mirrors {!Observer_server}'s lifecycle shape ([create], [run ~stop], [close]) so it plugs into [proxy.ml] the same
    way, but speaks WebSocket ([httpun-ws]) instead of the raw length-delimited observer protocol, and is
    one-way-authenticated (token + Origin) since it is reachable from any process on the same host, not just one holding
    a private, mode-restricted Unix-domain socket path.

    {2 Authentication/permission model}

    Binds only numeric [127.0.0.1] ([Unix.inet_addr_loopback]), never a public interface. A 16-byte token, read from
    [/dev/urandom] and hex-encoded at {!create} time (or supplied by the caller/[TESSERA_PROXY_WEB_TOKEN] -- see below),
    gates the one route that opens the live-screen channel, [GET /session]: missing/wrong token -> [403], no upgrade
    attempted, no {!Tessera_proxy_web_publisher.Web_publisher.attach} call made. Every other route (the static page and
    its subresources) is public and carries no session content, only fixed code compiled into this binary -- a browser's
    ordinary [<script src>]/[<link href>]/[@font-face] subresource requests do not (and must not be made to) inherit
    [?token=...] from the document URL. [Origin] is checked alongside the token on [/session] only: a *present* [Origin]
    that isn't exactly [http://127.0.0.1:<port>] is rejected; a *missing* Origin is allowed through (manual/test tooling
    with no browser Origin -- the token is what actually gates those). The token value is never logged.

    {2 Reconnect/resync model}

    [resync] is close-and-reconnect, not an in-band reset: on a client [Resync], this server replies [Result] then
    closes the connection with no corrective frame; the browser side ([web/proxy-web.js]) reconnects with a brand-new
    WebSocket *and* a brand-new [TesseraDriver] instance, which accepts an unconditional fresh reset regardless of
    whatever generation the old, now-discarded driver instance had already seen. This requires no change to
    [tessera-driver.js]'s existing, tested contract, and needs no [request_resync] entry point on
    {!Tessera_proxy_web_publisher.Web_publisher}: closing a connection is already a plain disconnect from the
    publisher's point of view.

    {2 A documented WebSocket-conformance exception}

    [httpun-ws] 0.2.0 never surfaces RSV-bit or client-mask-presence information to application code (its parser checks
    are present but structurally unreachable through its public API): an unmasked client frame (RFC 6455 section 5.1)
    and a frame with any RSV bit set (RFC 6455 section 5.2) are both silently accepted and processed as if valid. This
    is accepted, deliberately, for this deployment: the loopback-only bind + token gate means the intended client (a
    real browser) always masks correctly regardless of any of this, there is no network intermediary on a same-host
    loopback hop for the mask-defends-against-cache-poisoning threat to apply to, and no WebSocket extension is ever
    negotiated, so an ignored RSV bit has no compression/extension behaviour to abuse. This must be revisited if this
    transport is ever reused for a non-loopback deployment, or if extension support is ever added.

    {2 Connection lifecycle}

    This module owns each accepted descriptor through a small local Lwt driver around the [httpun]/[httpun-ws] protocol
    state machines. A peer EOF, write failure, or server-initiated terminal path closes that descriptor and runs one
    idempotent cleanup function, which detaches any attached publisher client. In particular, an ungraceful client
    disconnect cannot leave a stale client in {!client_count}; the real-loopback regression is in
    [test/proxy_linux/web_server_test.ml]. *)

type error =
  [ `Bind_failed of Unix.error
  | `Listen_failed of Unix.error
  | `Socket_failed of Unix.error
  | `Token_unavailable of Unix.error ]

module E : Err.S with type error = error

val pp_error : Format.formatter -> error -> unit

type t

type input_handler = bytes -> (unit, string) result
(** A non-blocking handoff into the proxy session's bounded PTY-input queue. [Ok ()] means accepted/queued; [Error] is
    safe to expose as a command error. *)

val create :
  ?port:int ->
  ?token:string ->
  ?ready_file:string ->
  ?input:input_handler ->
  ?allow_control:bool ->
  max_pending_bytes:int ->
  write_timeout:float ->
  close_flush_timeout:float ->
  unit ->
  (t, error) Err.t
(** [port]/[token]/[ready_file] default to reading [TESSERA_PROXY_WEB_PORT]/[TESSERA_PROXY_WEB_TOKEN]/
    [TESSERA_PROXY_WEB_READY_FILE] from the environment (the deterministic hook the subprocess-spawning Playwright/ Node
    test layers use against the real [tessera-proxy] executable), falling back to an ephemeral kernel-chosen port and a
    freshly generated random token when those are also unset. Passing them explicitly (as
    [test/proxy_linux/web_server_test.ml]'s in-process layer does) bypasses the environment entirely -- both callers
    exist because [proxy.ml] wants the env-var hook with zero extra plumbing, while an in-process OCaml test wants a
    fixed port/token without mutating global process state.

    [input] and [allow_control] are both required to advertise or grant the stage-3 browser controller lease. They
    default to disabled, retaining the release-one read-only endpoint. The composition root enables them only for an
    explicit local policy. [max_pending_bytes] bounds each client's own queued-but-unsent output, exactly like
    {!Observer_server.create}'s parameter of the same name. [write_timeout] is how long a connected client may go
    without draining its own socket before this server force-closes its descriptor. [close_flush_timeout] bounds the
    final best-effort wait on [Wsd.flushed] after a server-initiated close (protocol violation, [Resync], [Close]); when
    it expires, this module closes the descriptor and detaches the client. A live, reading peer receives the
    Error/Result and Close frames as soon as its writer loop flushes them.

    If reading/generating the token fails (e.g. [/dev/urandom] is unavailable), returns [`Token_unavailable] rather than
    falling back to weak randomness; the caller ([proxy.ml]) is expected to log this and disable the web endpoint for
    this run, exactly like {!create_observer_server}'s existing degrade-on-failure behaviour. *)

val port : t -> int
val token : t -> string

val bootstrap_url : t -> string
(** [http://127.0.0.1:<port>/?token=<token>] -- the one URL a caller should print/open. *)

val note_outcome : t -> Tessera.outcome -> unit
(** Forwards to {!Tessera_proxy_web_publisher.Web_publisher.note_outcome} and wakes every attached connection's writer
    task; a build failure there is logged (via {!pp_error} on stderr) and otherwise ignored -- a projection failure must
    never perturb the relay this shares an event loop with. Never blocks. *)

val run : t -> stop:unit Lwt.t -> unit Lwt.t
(** Watches the listen socket and accepts connections until [stop] resolves, mirroring {!Observer_server.run}/[accept].
*)

val client_count : t -> int
(** The number of currently-attached (post-[Hello]) {!Tessera_proxy_web_publisher.Web_publisher} clients. For
    diagnostics/tests only. *)

val physical_input_allowed : t -> bool
(** [false] exactly while an attached browser owns the controller lease. The proxy session uses this predicate to
    prevent physical-terminal bytes from racing an explicitly granted web controller. *)

val close : t -> unit
(** Closes the listen socket, so no new connection is accepted. Idempotent and synchronous, like
    {!Observer_server.close}. It also closes every currently accepted descriptor through its lifecycle task, detaching
    each attached publisher client. *)
