(** A private, local Unix-domain socket server exposing {!Tessera_proxy_observer.Ring.t} to read-only observer clients
    through {!Tessera_proxy_protocol.Frame}, per milestones.md's "observable proxy service": a newly connected client
    receives an authoritative snapshot and cursor, then every later record in order; a client that falls behind receives
    an explicit gap and a fresh snapshot instead of stalling the relay.

    {2 Authentication/permission model}

    A client is trusted exactly as much as the local filesystem trusts it to reach the socket path at all: {!create}
    creates a private directory (mode [0o700]) to hold the socket, then the socket file itself is also created
    mode-restricted ([0o600] after [bind], since [Unix.bind] does not take a mode and a POSIX [AF_UNIX] socket's default
    mode depends on the process umask). Both are owned by this process's effective user. On Linux/POSIX, reaching a
    socket path at all requires search (execute) permission on every containing directory, so a [0o700] directory
    already limits [connect] to the same user (or root) without needing [SO_PEERCRED]/[getsockopt] -- this is the same
    trust model `ssh-agent` and `tmux` already use for their own control sockets, and it needs no new C stub (this
    package only links plain [Unix]/[Lwt], unlike [tessera_proxy_platform], which is the one package permitted C stubs
    per proxy.md's package layout). Peer-credential checking via [SO_PEERCRED] would be strictly stronger (it would also
    reject a same-user process that somehow reached the path through a bind-mount or a shared, wrongly-permissioned
    parent directory), but it needs a C stub this increment does not introduce; it is a documented, deliberate scope
    decision, not an oversight, and a natural follow-on hardening step.

    {2 Concurrency model}

    Every connected client owns two independent Lwt tasks -- a reader (discards whatever a read-only client sends, per
    the contract below) and a writer (drains that client's own pending-bytes buffer via non-blocking writes, woken
    whenever {!note_outcome}/{!drain}/{!accept} add to it) -- rather than the caller polling a read-fd-set/write-fd-set
    through a shared [select]. {!note_outcome}, {!drain}, and {!accept} stay synchronous and never block: they only ever
    append to an in-memory per-client buffer (or decide, per the [max_pending_bytes] policy below, to reset it to a
    {!Protocol.Gap} instead of growing it), never perform a socket write themselves. *)

type error =
  [ `Bind_failed of Unix.error
  | `Directory_failed of Unix.error
  | `Listen_failed of Unix.error
  | `Socket_failed of Unix.error ]

module E : Err.S with type error = error

val pp_error : Format.formatter -> error -> unit

type t

val create :
  socket_path:string ->
  ring:Tessera_proxy_observer.Ring.t ->
  policy:Tessera_foundation.Policy.t ->
  max_pending_bytes:int ->
  (t, error) Err.t
(** [socket_path]'s parent directory is created mode [0o700] if it does not already exist (an existing directory is left
    as-is: the caller is responsible for choosing a path whose parent it trusts). [max_pending_bytes] bounds how much
    encoded-but-not-yet-written output this server buffers per connected client before deciding that client is too slow
    and forcing it to resynchronise from a fresh snapshot instead of growing the buffer further. *)

val note_outcome : t -> Tessera.outcome -> unit
(** Records the most recent core outcome, so a client connecting (or resynchronising) right now has a snapshot to
    receive, then behaves exactly like {!drain}. Call this once per {!Tessera.outcome} the proxy's relay loop already
    produces -- it never publishes to {!Tessera_proxy_observer.Ring.t} itself (the relay loop still owns that) and never
    blocks. *)

val drain : t -> unit
(** Attempts to forward every {!Tessera_proxy_observer.Ring.t} record published since each client's own last position
    into that client's pending output, up to [max_pending_bytes]; a client that would exceed the bound, or that the ring
    itself reports a gap for, is instead sent a {!Tessera_proxy_protocol.Frame.Gap} and a fresh snapshot (using the most
    recent {!note_outcome}, if one has been recorded). Call this after any {!Tessera_proxy_observer.Ring.publish} the
    caller makes that {!note_outcome} does not already cover -- terminal-to-application traffic, in particular, has no
    accompanying {!Tessera.outcome}. Never blocks. *)

val accept : t -> unit
(** Call when a caller (typically {!run}) has observed the listen socket readable. Accepts every pending connection
    (non-blocking; stops at [EAGAIN]), and for each spawns its reader/writer Lwt tasks and immediately attempts to send
    a snapshot if {!note_outcome} has already recorded one -- otherwise the client is queued and receives its first
    snapshot as soon as one is available. Never blocks. *)

val run : t -> stop:unit Lwt.t -> unit Lwt.t
(** Watches the listen socket and calls {!accept} whenever it is readable, until [stop] resolves. Pass a promise the
    composition root resolves once the proxy's relay (master/terminal loops) has ended the session -- a listen socket
    has no EOF of its own to terminate on, mirroring {!Session.run_resize_loop}'s [stop] parameter. *)

val client_count : t -> int
(** For diagnostics/tests only. *)

val close : t -> unit
(** Closes the listen socket and every connected client (waiting for each close to actually complete), and unlinks
    {!create}'s [socket_path]. Idempotent. Synchronous: runs its own short-lived Lwt scheduler turn internally, so it is
    safe to call after an outer {!Lwt_main.run} (e.g. {!Session.run_master_loop}'s driver) has already returned. *)
