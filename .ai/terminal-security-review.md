# Tessera: C-stub and effect security review

Milestone 8 ("release hardening") review of the two areas terminal-plan.md's
dependency table calls out as the only places this project is allowed
operating-system-level or memory-unsafe surface: the Linux PTY/signal C stubs,
and the effect/observation data that crosses from those stubs into the
portable core and the observer wire protocol. Review basis: the tree at the
point milestone 6's checkpoint codec, the observer wire protocol/socket
server, and the proxy checkpoint envelope had just landed.

## Scope

- `lib/proxy_platform/platform_stubs.c` and its OCaml binding
  (`lib/proxy_platform/platform_linux.ml`): GC-root discipline, buffer
  bounds/integer overflow across the OCaml/C boundary, errno propagation, and
  the async-signal-safety constraint from terminal-plan.md's "Resize
  protocol" section.
- OCaml 5 effect-handler usage anywhere in this project's own code (not
  vendored submodules), and, since none exists, the `Tessera.Effect`
  observation/diagnostic data path from decoder to the observer wire protocol
  (`lib/proxy_protocol/frame.ml`): must never carry a raw signal, descriptor,
  or unbounded/unvalidated payload.
- `lib/proxy_linux/observer_server.ml` and `lib/proxy_linux/proxy.ml`'s
  select-loop composition: descriptor lifecycle on every exit path, and
  whether the "every socket write is non-blocking" claim from the observer
  server's own commit actually holds.

## Findings fixed

**Observer socket descriptor leak on `create` failure.** `Observer_server.create`
opens the listening socket with `Unix.socket` before binding, then chmod-ing,
then listening. The `Bind_failed` and `Listen_failed` error branches returned
`Error` without closing that already-allocated descriptor, leaking one file
descriptor per failed `create` call (e.g. a proxy restart loop that keeps
hitting the same bind failure). Fixed by closing the descriptor inside each
`catch` handler before constructing the error. Regression test: "a create
that fails after allocating a socket does not leak its descriptor"
(`test/proxy_linux/observer_server_test.ml`), which forces a deterministic
post-`socket()` bind failure (a directory component that is actually a
regular file, so `bind` fails with `ENOTDIR` regardless of the run's
filesystem permissions or effective user) and asserts `/proc/self/fd`'s count
does not grow across 50 failed attempts.

**Observer listening socket missing `FD_CLOEXEC`.** `accept` already creates
every client socket with `~cloexec:true`, but the listening socket itself was
created with plain `Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0`. In the
current composition root (`proxy.ml`) this is not exploitable today, since
`Observer_server.create` runs strictly after `Session.create`'s `fork`+`exec`
of the proxied application, so the listening fd does not exist yet at the one
`exec` this process ever performs. It is still a latent hazard for any future
caller that creates the observer server before spawning a child, or spawns a
second child later, since an inherited listening socket would let a
compromised child `accept` connections on it after this process closes its
own copy. Fixed by adding `~cloexec:true` to the `Unix.socket` call, matching
the client-socket convention already established in the same file. No new
test: this closes a hazard for call orders the current codebase does not
exercise, and the existing "create restricts both the socket's directory and
the socket file itself to this user" test already covers this server's
observable client-facing behavior.

**Winsize fields silently truncated past `struct winsize`'s `unsigned short`
range.** `platform_stubs.c`'s `tessera_openpty_stub`/`tessera_set_winsize_stub`
cast their `rows`/`cols`/`xpixel`/`ypixel` `int` arguments directly to
`unsigned short`. `Tessera_foundation.UInt.t` (which backs
`Tessera_proxy_platform.Winsize.t`'s columns/rows) has no upper bound of its
own beyond the native `int` width, and `Winsize.t`'s pixel fields are plain,
unconstrained `int`. In the current `tessera-proxy` executable this is not
reachable with a bad value, since every real geometry originates from a
`TIOCGWINSZ` readback (the kernel's own `struct winsize` is already
`unsigned short`-bounded), but `Platform.S` is a public library signature:
any caller that constructs a synthetic `Winsize.t` (a test, an alternate
composition root, a future non-hardware-backed adapter) and passes it to
`spawn`/`set_winsize` would previously have gotten a silently wrong,
wrapped-around geometry applied to the real PTY instead of a typed error —
exactly the kind of silent geometry corruption terminal-plan.md's resize
protocol is designed to rule out. Fixed by validating each of the four fields
against `[0, 0xFFFF]` in `platform_linux.ml`'s `raw_of_winsize` (the one
OCaml-side chokepoint both `spawn` and `set_winsize` already call before
reaching the C stubs), raising `Unix.Unix_error (EINVAL, "winsize", ...)` so
it flows through the existing `wrap_unix_error` path as an ordinary,
already-handled error rather than needing a new error variant or a `Platform.S`
signature change. Regression test: two new checks in
`test/proxy_platform_linux/platform_linux_test.ml` — a `set_winsize` call
with a 100,000-column request is rejected, and the previously applied real
geometry is left untouched by the rejected call (queried back with
`get_winsize` over the real PTY).

## Checked and found sound (no change)

**GC-root discipline in `platform_stubs.c`.** Every `external` takes only
immediate (`int`/`Unix.file_descr`-as-int) arguments; none are boxed values
requiring a GC root across an allocating call. Every stub that does allocate
(`tessera_openpty_stub`, `tessera_get_winsize_stub`) registers its result
tuple with `CAMLlocal1` before `caml_alloc_tuple` and only stores immediates
(`Val_int`) into it with `Store_field`, so no write barrier
(`caml_modify`)/root-tracking gap exists. `CAMLparam`/`CAMLreturn` bracket
every stub correctly.

**Errno propagation.** Every stub that can fail calls `uerror(fn, Nothing)`
(the standard `caml/unixsupport.h` helper), which raises `Unix.Unix_error`
with the real `errno`. Every OCaml call site (`wrap_unix_error` in
`platform_linux.ml`) converts that into this project's typed `error` variant
rather than letting an exception escape to the composition root uncaught.

**Async-signal-safety.** terminal-plan.md requires that "a signal handler may
only wake the loop using async-signal-safe work: it must not allocate, run
OCaml, perform an ioctl, mutate the renderer, or publish observer events."
This binding installs no OCaml or C signal handler at all for `SIGWINCH`:
`tessera_block_sigwinch_signalfd_stub` blocks the signal process-wide with
`sigprocmask` and hands back a `signalfd`, so delivery is observed as
ordinary, synchronous descriptor readiness in the main poll loop, never from
signal-handler context. The constraint is satisfied by construction, not by
a handler that happens to be careful. `tessera_reset_child_signals_stub`
correctly unblocks the forked child's mask before `execvp`, so a spawned
program is never left with `SIGWINCH` unexpectedly blocked.

**OCaml 5 effect handlers.** Neither `effect`/`perform` nor
`Effect.Deep`/`Effect.Shallow` appear anywhere in `lib/` or in this project's
own use of `vendor/`. `Tessera.Effect` is exclusively the pure
observation/diagnostic data vocabulary terminal-plan.md documents it as; it
has no relationship to OCaml 5's effect-handler feature.

**Effect/diagnostic data never carries raw OS state.** `Tessera.Effect.observation`
has exactly two constructors: `Resize` (a validated `Types.Size.t`, never a
raw `winsize` or signal) and `Diagnostic`, whose `kind`/`reason`/`family`
string fields are, at every construction site in `lib/decoder/decoder.ml`,
fixed literal strings the decoder itself chooses (`"OSC"`, `"CSI"`,
`"parameter count exceeds policy"`, ...) — never a substring copied from
arbitrary input bytes, and never a descriptor or pointer. The same
observation type is what `lib/proxy_protocol/frame.ml`'s
`encode_observation`/`decode_observation` serialize onto the wire, so this
invariant carries through to the observer protocol unchanged.

**Observer server descriptor lifecycle, remaining paths.** `remove_client`
closes and forgets a client on every removal path (`on_readable`'s EOF/hard
error, `flush`'s hard write error). `close` closes the listen socket and
every connected client and unlinks the socket path, and is called from
`proxy.ml`'s `Fun.protect ~finally`, so it runs on every exit from `run_loop`
including an application EOF or a terminal EOF. `service_all` re-snapshots
`t.clients` before iterating so a removal mid-iteration (via `advance`'s
resync path or `flush`'s hard-error path) never skips or revisits an entry.

**"Every socket write is non-blocking."** Spot-checked directly: the only
`Unix.write` call in `observer_server.ml` is in `flush`, on a socket already
set non-blocking in both `create` (listen socket; irrelevant, never written
to) and `accept` (every client socket, via `Unix.set_nonblock fd` right after
`accept`). `flush`'s exception cases explicitly treat
`EAGAIN`/`EWOULDBLOCK`/`EINTR` as "wrote nothing, try later" and every other
`Unix_error` as "the peer is gone, remove it" — there is no path that retries
a write in a loop or blocks waiting for writability. This matches the
existing "a stalled, non-reading observer client never delays or corrupts
the byte relay" test, which would hang (and therefore fail the test runner's
own timeout) if any write here ever blocked.

## Accepted risk for release one

**No `SO_PEERCRED` peer-credential check on the observer socket.** Documented
already in `lib/proxy_linux/observer_server.mli`: the trust model is a
`0700` socket directory plus a `0600` socket file, the same model
`ssh-agent`/`tmux` use for their own control sockets. Reaching the socket
path at all requires directory search permission, which already restricts
`connect` to the same effective user (or root) without a C stub — this
package deliberately links only `Unix`, since `tessera_proxy_platform` is
the one package proxy.md's package layout permits C stubs in.
`SO_PEERCRED`/`getsockopt` would be strictly stronger (it would also reject
a same-user process that reached the path through an unexpected bind-mount
or a wrongly-permissioned parent directory), but that gap requires a
filesystem misconfiguration outside this process's control, and closing it
needs a new C stub. This review confirms that decision rather than
second-guessing it: reopening it is a reasonable, separate future hardening
step, not a defect in this increment.

**No upper bound on `Foundation.UInt.t`/`Limits.max_columns`/`max_rows`
beyond zero.** `Limits.make` only rejects a zero `max_columns`/`max_rows`/
`max_snapshot_cells`; nothing stops a caller from configuring a policy whose
*current-geometry* ceiling exceeds `0xFFFF`. This is intentionally left
alone here: the policy's `max_columns`/`max_rows` bound the logical renderer,
not the physical PTY `winsize` directly (`proxy.ml`'s own comment says as
much), and the new `check_winsize_field` validation in `platform_linux.ml`
is the correct enforcement point precisely because it sits at the actual
OS-facing boundary — the one place a `struct winsize`-shaped constraint
belongs, rather than being duplicated into the portable core's own,
otherwise host-independent, `Limits`.
