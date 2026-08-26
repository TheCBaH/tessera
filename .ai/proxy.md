# Tessera Linux proxy: implementation document

## Deliverable

This document specifies the three remaining Linux-proxy items:

1. the Linux proxy platform boundary and observer schema;
2. `TIOCGWINSZ`/`TIOCSWINSZ` handling, resize wake-up, same-size child
   `SIGWINCH` preservation, lifecycle re-query, and transparent relay tests;
3. bounded observer delivery with ordered traffic/resize/effect records, gap
   reporting, and authoritative snapshot resynchronisation.

It is scoped narrowly on purpose. [terminal-plan.md](terminal-plan.md)
sketches a larger eventual proxy (`tessera-proxy-protocol`'s FlatBuffers wire
schema, a Unix-domain observer socket server, process discovery). None of
that is required to close the three items above, and none of it is designed
here: this document ends at an in-process, typed OCaml boundary for both the
platform and the observer feed. A wire encoding and a socket server are a
later, separate increment that consumes the API specified here, the same way
`lib/unix_adapter` already consumes `Tessera.Session` without knowing
anything about FlatBuffers or sockets.

This builds directly on work already committed: `lib/unix_adapter`
(`Tessera_unix.Unix_adapter`) already serialises byte ingress and validated
resize through `Session.ingest`/`finish` with a lock held only around the
brief mutation, and `test/conformance` already provides a reusable,
scheduler-independent `Scenario`/`Reference` fixture. The proxy reuses both
rather than re-solving session serialisation from scratch.

## Package layout

    lib/
      proxy_platform/         # tessera_proxy_platform
        platform.mli           # module type S; the audited boundary
        platform_linux.ml       # real openpty/forkpty/ioctl/signalfd C-stub binding
      proxy_observer/         # tessera_proxy_observer
        record.ml               # traffic/resize/effect record types, sequence numbers
        ring.ml                 # bounded delivery ring: publish, gap counting, resync
      proxy_linux/             # tessera_proxy_linux
        resize_loop.ml           # the resize protocol, generic over Platform.S
        session.ml               # proxy session: Unix_adapter + platform + observer ring
        proxy.ml                 # composition root / eventual tessera-proxy executable

`tessera_proxy_platform` is the only package permitted C stubs, `Unix`
ioctl/signal calls beyond what `unix`/`threads` already provide, and process
primitives (`openpty`, `forkpty`, `waitpid`). `tessera_proxy_observer` is
pure OCaml: it depends on `tessera` for `Effect`/`Update`/geometry types but
touches no descriptor, signal, or C stub. `tessera_proxy_linux` is the
composition root; it is the only package allowed to depend on all of
`tessera_unix`, `tessera_proxy_platform`, and `tessera_proxy_observer`
together.

## 1. Platform boundary

`Tessera_proxy_platform.S` is a module type, not a concrete module, so the
resize protocol and the relay loop can be tested against a fake
implementation without a real PTY, a real child process, or a real signal --
mirroring how `test/conformance`'s `Scenario`/`Reference` decouples ingress
ordering from any real scheduler.

```ocaml
module type S = sig
  type pty
  (** An open PTY pair (master + slave), with a child already attached to the slave side. *)

  type error

  val pp_error : Format.formatter -> error -> unit

  val spawn : argv:string array -> initial_winsize:Winsize.t -> (pty, error) result
  (** Opens a PTY, forks, execs [argv] on the slave side with the slave as its controlling
      terminal, and applies [initial_winsize] before the child runs. *)

  val master_fd : pty -> Unix.file_descr
  (** The descriptor to read child output from and write terminal input to. Never the slave. *)

  val get_winsize : pty -> (Winsize.t, error) result
  (** [TIOCGWINSZ] on the master. *)

  val set_winsize : pty -> Winsize.t -> (unit, error) result
  (** [TIOCSWINSZ] on the master. The kernel notifies the slave's foreground process group with
      [SIGWINCH] as a side effect exactly when the applied value differs from the previous one;
      callers must not assume an unconditional notification. *)

  val notify_unchanged_winsize : pty -> (unit, error) result
  (** Sends one [SIGWINCH] to the slave's foreground process group directly, for the case
      documented in {!section:resize-protocol}: a host notification whose winsize equals what is
      already applied, where [set_winsize] alone would not signal the child. *)

  val resize_wakeup_fd : pty -> Unix.file_descr
  (** A descriptor that becomes readable exactly when a host resize notification (the physical
      terminal's own [SIGWINCH], relayed through a blocked-signal + [signalfd] or a self-pipe) has
      arrived. Readers must drain it (it may coalesce several notifications into one readable
      event) and then call {!get_winsize} on the *physical* terminal descriptor, not [pty], to
      learn the new value -- this descriptor only wakes the loop, it carries no geometry. *)

  val physical_winsize : unit -> (Winsize.t, error) result
  (** [TIOCGWINSZ] on the process's own controlling terminal (fd 0/1/2), i.e. the host side, not
      the child PTY. *)
end
```

`Winsize.t` is a new small `tessera_proxy_platform` type: validated
`rows`/`columns` (reusing `Tessera_foundation.Types.Size.t` for the part that
becomes core geometry) plus an optional pixel extent tagged with a unit
(`Device_pixels | Css_pixels | Unspecified`), per terminal-impl.md's
checkpoint section: "Preserve optional unit-tagged pixel metadata outside
`Size.t`." Pixel fields are proxy metadata; they are never part of
`Tessera_foundation.Types.Size.t` and never reach the renderer.

### Signal safety

Per terminal-plan.md's already-decided rule: block `SIGWINCH` in the process
and receive it only through `signalfd` (or a minimal self-pipe handler on
platforms without `signalfd`) drained from the main poll loop. The one
statement permitted to run inside the actual signal handler, if a self-pipe
is used instead of `signalfd`, is a single async-signal-safe `write` of one
byte to the pipe's write end. A handler must never allocate, call into the
OCaml runtime, run an ioctl, mutate the renderer, or publish an observer
record. `resize_wakeup_fd` is what makes this true by construction: all real
work (querying `physical_winsize`, deciding same-size-preservation, calling
`set_winsize`, calling `Session.ingest`) happens after the main loop observes
the descriptor is readable, never inside signal delivery itself.

## 2. Resize protocol {#resize-protocol}

This is terminal-plan.md's resize protocol, restated as an algorithm against
`Platform.S` and `Tessera_unix.Unix_adapter`.

**Startup.** Call `physical_winsize ()`, validate positive rows/columns
(`Foundation.Types.Size.make`), `spawn` the child with that value as
`initial_winsize`, then `Unix_adapter.create` with that same validated size.
No `Out_of_band (Resize _)` is ingested for the initial size: `create`
already establishes it, matching how `Unix_adapter`/`Lwt_adapter`/
`Async_adapter` all take `~size` at construction rather than ingesting a
first resize.

**On `resize_wakeup_fd` readable.** Drain the descriptor (read until it would
block; a coalesced burst of host `SIGWINCH` delivers as one or a few
readable events, never one event per signal). Then:

1. Query `physical_winsize ()`. A failed query leaves both the child PTY and
   the renderer at their last known values and is reported through the
   adapter's own error channel -- it is never fabricated into a core update.
2. If rows or columns are zero/invalid, `set_winsize pty` the raw value
   anyway when possible (the child still gets what the physical terminal
   reported), but do not call `Unix_adapter.resize`; report an explicit
   unmodelled-resize diagnostic instead of guessing a geometry.
3. Otherwise, compare the new value's rows/columns against the value most
   recently applied to `pty`.
   - **Distinct:** `set_winsize pty new_value`. The kernel's own `SIGWINCH`
     delivery to the child is sufficient; do not additionally call
     `notify_unchanged_winsize`.
   - **Same:** `set_winsize` would apply an identical value and the kernel
     would not raise `SIGWINCH`, so explicitly call
     `notify_unchanged_winsize pty` instead. This is the
     notification-equivalent propagation terminal-plan.md requires: the host
     told us a resize happened even though the resolved geometry is
     unchanged, so the child must still be woken to re-query with its own
     `TIOCGWINSZ` and redraw.
4. Either way, call `Unix_adapter.resize adapter ~columns ~rows` with the
   *character* geometry (pixel fields never reach this call), including the
   same-size case: `Unix_adapter`/`Session` already model a same-geometry
   resize as a full-projection refresh (terminal-impl.md section 2), so the
   core-side behaviour for "same size, real notification" is already
   correct without special-casing it here.

**Ordering against child output.** When the wake-up descriptor and the child
PTY's master descriptor are *both* readable in the same poll iteration,
process the resize wake-up first, then read child output. This is
terminal-plan.md's rule ("this favours the geometry that the foreground
application is about to use for its `SIGWINCH` redraw") and is exactly
`Unix_adapter.resize`/`Unix_adapter.read_step`'s existing lock-ordering
guarantee applied at the poll layer: the proxy loop, not `Unix_adapter`
itself, is responsible for checking the wake-up descriptor before the read
descriptor in its `select`/`poll` set ordering.

**Lifecycle re-query points.** Call the same wake-up-handling logic above
(steps 1-4, without an actual signal having arrived) at: initial attach (the
startup case above already does this once), resume after suspension,
terminal reattachment, and immediately before resuming a paused relay.
Reconciliation is not a hidden renderer mutation; it goes through the
identical `Unix_adapter.resize` call as a live notification.

**What never happens.** The proxy never injects `CSI 18 t` or any other
size-report control sequence on its own initiative; xterm window-manipulation
replies, if the application emits them, are relayed transparently like any
other application byte, never synthesised. Raw signal numbers, `winsize`
structs, and descriptor readiness never cross into `Session.ingest`,
a checkpoint, or an observer record -- only the validated
`Foundation.Types.Size.t` produced by step 3/4 does.

## 3. Byte relay

Two independent directions, both relayed verbatim; only one is decoded.

- **Application-to-terminal** (child PTY master read → real terminal
  stdout write, and → `Unix_adapter.read_step`'s ingest path): this is the
  direction `Tessera.Session` models. The proxy writes every byte it reads
  from `master_fd` to the real terminal unchanged, and separately -- not
  instead -- ingests the same bytes through `Unix_adapter`, exactly as
  `test/unix_adapter` already exercises. Decoding never delays or alters the
  bytes actually written to the terminal; if ingest reports a typed error,
  relay continues and the error is reported through the adapter's own error
  channel, per `Unix_adapter.run`'s documented behaviour of stopping *its own
  loop* on error while the proxy's relay loop is a separate concern.
- **Terminal-to-application** (real terminal stdin read → child PTY master
  write): relayed verbatim, in the observed dequeue order, and never passed
  to `Session.ingest` -- the renderer models what the application displays,
  not what the user types. Where it is safe to do so, a byte range is tagged
  with a direction (`Application_to_terminal` / `Terminal_to_application`)
  purely for the observer traffic record described below. terminal-plan.md's
  data-type table anticipates this as `Tessera.Types.direction`, but it does
  not exist in `lib/foundation/types.mli` yet; adding that small two-case
  type (or an equivalent local to `tessera_proxy_observer` if it turns out to
  have no other core-side use) is part of this increment, not something to
  assume is already there. Either way, this classification never feeds back
  into decoding.

Each direction keeps its own single writer, matching terminal-impl.md's
"Each direction has one ordered write queue; adapters must never issue
concurrent writes on the same terminal/application stream."

## 4. Observer schema and bounded delivery

`Tessera_proxy_observer` is the in-process API that satisfies todo item 3.
It is deliberately not a wire format: a later `tessera_proxy_protocol`
package would define the FlatBuffers encoding of the same records, and a
later `tessera_proxy_linux` socket server would be its transport. Neither is
specified here.

```ocaml
module Record : sig
  type sequence = private int
  (** Monotonically increasing per proxy session; never reset except by a new lineage. *)

  type traffic = { sequence : sequence; direction : Tessera_foundation.Types.direction; bytes : Bytes.t }
  type resize = { sequence : sequence; size : Tessera_foundation.Types.Size.t; pixels : Pixels.t option }
  type effect = { sequence : sequence; item : Tessera.Effect.observation }

  type t = Traffic of traffic | Resize of resize | Effect of effect
end

module Ring : sig
  type t
  (** A bounded, single-producer, multi-consumer record log. *)

  val create : capacity:int -> t
  val publish : t -> Record.t -> unit
  (** Never blocks and never raises. Publishing into a full ring overwrites the oldest retained
      record; the producer (the relay loop) must never be slowed by a lagging observer. *)

  type cursor
  (** One observer's read position. *)

  val cursor : t -> cursor
  (** A cursor starting after every record currently retained (a fresh observer must resync from
      a snapshot first, per {!authoritative_snapshot}, not replay history it never subscribed to). *)

  type read = Record of Record.t * cursor | Gap of { skipped : int; resume : cursor }
  (** [Gap] is returned instead of silently skipping: the caller learns exactly how many records
      were dropped and receives a cursor positioned after the gap, so it knows to resynchronise. *)

  val read : t -> cursor -> read option
  (** [None] means caught up to the producer; not an error. *)
end

val authoritative_snapshot : Tessera.session -> Model.Collection.Snapshot_cells.t * cursor
(** The current renderer snapshot paired with a cursor positioned to read every record published
    after it. A client that receives a {!Gap} discards what it has and rebuilds from this pair
    instead of trying to patch around the hole. *)
```

**Ordering.** `Ring.publish` is called once per traffic write (each
direction), once per resize (immediately after step 4 of the resize
protocol, i.e. after the core has already applied it, so the record's `size`
matches what `Session`/`Renderer` now hold), and once per
`Tessera.Effect.observation` the core emits during `ingest`/`finish`. All
three record kinds share one `sequence` counter, so an observer can tell
`Traffic`, `Resize`, and `Effect` apart from each other's true interleaving,
not just their own kind's order.

**Boundedness.** `Ring.create ~capacity` fixes the record budget up front, in
the spirit of terminal-impl.md's `Policy.limits`; there is no unbounded
growth path. A slow observer never applies backpressure to `publish` --
`Backpressure_pause`/`Backpressure_resume` in `test/conformance`'s vocabulary
describe exactly this non-effect on the ingress side, and the ring's `Gap`
result is the observer-side symmetric counterpart: cost is paid by making
the lagging reader recover from a snapshot, never by stalling the terminal.

**Authoritative resynchronisation.** `authoritative_snapshot`'s geometry is
always the renderer's current `Size.t`; an observer that resyncs from it and
then reads forward from the paired cursor cannot land on a geometry the
renderer never actually held, even if several resizes occurred while the
observer was catching up (each is still its own `Resize` record with its own
sequence number, per terminal-plan.md's "preserves every size observation
the adapter actually receives").

## 5. Composition

`lib/proxy_linux/session.ml` owns the mutable state a real deployment needs,
matching terminal-plan.md's "Proxy organisation": a `Tessera_unix.Unix_adapter.t`
(decoder continuation + renderer state, already lock-protected), a `Platform.pty`,
a `Ring.t`, and nothing else mutable -- no raw signal, no bare descriptor
readiness flag, no unwrapped `winsize`. The main loop is a `select`/`poll`
over three descriptors (`master_fd`, `resize_wakeup_fd`, real stdin) plus
whatever `Unix_adapter`'s own locking already serialises; it is new code, not
a reuse of `Unix_adapter.run` (`run` is a single-descriptor blocking loop by
design, per its own `.mli` doc, and the proxy inherently multiplexes three).

Checkpointing is out of scope for this increment (todo.md section 6 does not
list it as a remaining item), but the state above is deliberately shaped to
make it a small follow-on: terminal-impl.md's `Checkpoint.V1` already covers
the `Unix_adapter`-owned session; a proxy envelope adding description
identity and the `Ring`'s current `sequence`/cursor position (never the
`Platform.pty`, never `resize_wakeup_fd`, never anything signal-shaped) is
the only new surface, exactly as terminal-impl.md's checkpoint section
already anticipates ("A proxy may wrap `Checkpoint.V1` in its own versioned
envelope containing those two identities").

## Testing

Four independent layers, ordered from fastest/most-deterministic to
slowest/most-real, mirroring how `test/unix_adapter` added a real-OS layer
on top of `test/conformance`'s scheduler-independent fixture rather than
replacing it.

**1. Resize protocol logic, against a fake `Platform.S`.** A
`test/proxy_linux/fake_platform.ml` implements the module type with an
`Lwt`/thread-free, single `Unix.pipe` standing in for `resize_wakeup_fd`
(tests write a byte to simulate a host `SIGWINCH`) and mutable refs standing
in for the physical and child `winsize`. This makes every rule in section 2
a fast native `ppx_expect` test with no real signal, no real PTY, no timing
dependency:
  - distinct-size notification calls `set_winsize` and *not*
    `notify_unchanged_winsize`; same-size notification calls
    `notify_unchanged_winsize` and *not* a redundant `set_winsize` that
    would claim to change something it didn't;
  - a zero/invalid queried size calls `set_winsize` with the raw value (best
    effort to the child) but does *not* call `Unix_adapter.resize`, and
    produces the documented diagnostic instead;
  - when the fake exposes both the wake-up pipe and a child-output pipe as
    simultaneously readable, the loop processes the resize before the
    pending output -- this is the one rule genuinely specific to the proxy's
    poll ordering (not something `test/conformance`'s single-descriptor
    scenarios can express) and needs its own scripted test here rather than
    an addition to `Scenario.host_event`;
  - each lifecycle re-query point (attach, resume, reattach, pre-resume)
    calls the fake's `physical_winsize`/`set_winsize` through the identical
    path as a live wake-up, asserted by call-count/argument capture on the
    fake, not by re-deriving section 2's rules a second time.

**2. Ingress ordering and content, reusing `test/conformance` directly.**
The application-to-terminal relay path funnels through the same
`Unix_adapter` primitives `test/unix_adapter` already validates; the proxy
does not need its own copy of `Scenario.all`. What the proxy *adds* on top
-- verbatim relay to the real terminal happening independently of ingest
succeeding or failing -- is covered by asserting that bytes written to the
fake child-output pipe are also observed (byte-for-byte) on the fake
terminal-output sink even when a scripted `Failure` stops ingest, i.e. the
transparent-relay half of terminal-plan.md's "Application-to-terminal bytes
are written verbatim... Decoding never delays or alters the bytes actually
written."

**3. `Ring`/observer tests, pure and scripted.** No descriptor or signal
involved:
  - publishing past `capacity` returns `Gap` with the correct `skipped`
    count on the next `read`, never blocks the publisher (assert this by
    publishing far more records than capacity in a tight loop with no
    intervening reads and checking it returns promptly);
  - a consumer that reads every record via `read` and one that hits a `Gap`,
    resyncs via `authoritative_snapshot`, and reads forward from its cursor
    converge on the same final `Snapshot_cells.t` -- this is the
    counterpart to `test/conformance/conformance.ml`'s existing snapshot-
    completeness check, but exercised against `Ring`'s actual drop/gap
    behaviour rather than only against `Session`'s own snapshot, which is a
    materially different (currently untested) code path;
  - `sequence` ordering across all three `Record.t` kinds is checked by
    publishing an interleaved traffic/resize/effect script and asserting the
    read-back order matches publish order exactly, not just each kind's own
    sub-order.

**4. Real integration, Linux-only.** These are the "transparent relay tests"
todo item 2 names explicitly, gated the way `vendor/err_trace`'s melange
target is gated on an env var, but here on platform (`(enabled_if (= %{system} linux))`
or equivalent): spawn a real child (a tiny purpose-built test helper that
prints its `TIOCGWINSZ` result on `SIGWINCH` and on startup is enough; no
need for a real shell), and assert against the *real* `Tessera_proxy_platform_linux`:
  - the child observes the exact `winsize` `spawn` applied at startup;
  - sending the process a real `SIGWINCH` (simulating a host notification by
    directly invoking whatever drives `physical_winsize`/`resize_wakeup_fd`
    in the test harness, since the test itself is not run inside a real
    terminal) results in exactly one `Unix_adapter.resize` call with the
    expected geometry and the child observing a real `SIGWINCH` in the
    same-size case;
  - byte-for-byte relay in both directions against a real PTY pair, the same
    invariant section 3 states, now proven end-to-end rather than through
    the fake sink.

Allocation-budget and fuzz-style testing, as already applied to the pure core,
do not apply here in the same way: the proxy loop
is I/O-bound, not allocation-sensitive in the way a hot decode/render path
is, and there is no untrusted-input parser boundary beyond what
`Tessera.Decoder`/`Tessera.Session` already fuzz-test. The one genuinely new
audited-boundary surface is the C stubs in `tessera_proxy_platform`
(`openpty`/`forkpty`/ioctl argument marshalling): review these by hand
against the same standard terminal-impl.md already applies to bounds-checked
parsing -- checked argument sizes, checked `errno` handling, no silent
truncation -- rather than by fuzzing, since their input space (a `winsize`
struct, a handful of syscalls) is small and enumerable by the tests in
layer 4 above.

## Implementation order

1. `Winsize.t` and `Tessera_proxy_platform.S` (the module type only), plus
   `fake_platform.ml` in `test/proxy_linux`. No real Linux binding yet.
2. `resize_loop.ml` against the fake: section 2's algorithm, fully covered
   by layer-1 tests above.
3. `Tessera_proxy_observer` (`Record`, `Ring`, `authoritative_snapshot`),
   covered by layer-3 tests. Independent of steps 1-2; can be built in
   parallel.
4. `Tessera_proxy_platform_linux`: the real C-stub-backed implementation of
   `S`, plus layer-4 integration tests. This is the only step that needs
   `(enabled_if (= %{system} linux))`-style gating and C stubs; everything
   above it is portable native OCaml, testable without Linux-specific
   syscalls at all.
5. `session.ml`/`proxy.ml`: wire steps 1-4 together into the composition
   root described in section 5. A minimal `tessera-proxy` executable (spawn
   a shell, relay, no observer transport yet) is the acceptance gate for
   this document; the wire protocol and socket server remain future work.
