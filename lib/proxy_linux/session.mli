(** The proxy session (proxy.md section 5): a real deployment's mutable state -- a {!Resize_loop.Make} instance (which
    itself owns the {!Tessera_lwt.Lwt_adapter.t} and [Platform.pty]) plus a {!Tessera_proxy_observer.Ring.t}, and
    nothing else mutable: no raw signal, no bare descriptor readiness flag, no unwrapped winsize. Generic over
    {!Tessera_proxy_platform.Platform.S} so it is testable against a fake platform, the same way {!Resize_loop.Make} is.
*)

module Make (Platform : Tessera_proxy_platform.Platform.S) : sig
  module Loop : module type of Resize_loop.Make (Platform)

  type t

  val create :
    argv:string array ->
    env:string array ->
    lineage_id:Tessera_foundation.Lineage_id.t ->
    policy:Tessera_foundation.Policy.t ->
    terminal_in:Unix.file_descr ->
    terminal_out:Unix.file_descr ->
    observer_capacity:int ->
    observer_start_position:Tessera_proxy_observer.Record.sequence ->
    read_buffer_bytes:int ->
    (t, Loop.error) result
  (** [terminal_in]/[terminal_out] are the real terminal's descriptors: application-to-terminal bytes are written
      verbatim to [terminal_out]; terminal-to-application bytes are read from [terminal_in] and relayed verbatim to the
      child, never ingested. [observer_start_position] is {!Tessera_proxy_observer.Record.initial_sequence} for a fresh
      session, or a {!Checkpoint.restored}'s [observer_position] when resuming from one -- see {!Checkpoint}. Every
      descriptor this session touches ([Platform.master_fd], [terminal_in], [terminal_out]) is wrapped once here via
      {!Lwt_unix.of_unix_file_descr} and reused for the session's lifetime, rather than re-wrapped on every read/write.
  *)

  val loop : t -> Loop.t
  val ring : t -> Tessera_proxy_observer.Ring.t

  type event =
    | Application_bytes of Tessera.outcome  (** Application-to-terminal bytes were relayed and successfully ingested. *)
    | Application_ingest_failed of Tessera_lwt.Lwt_adapter.error Err.Error.t
        (** The bytes were still relayed to the real terminal verbatim; only decoding/ingestion failed. *)
    | Application_eof of Tessera.outcome  (** The child's master reached EOF; {!Tessera.finish} ran. *)
    | Terminal_input_relayed of int  (** [n] bytes were read from [terminal_in] and relayed to the child, verbatim. *)
    | Terminal_input_eof  (** [terminal_in] reached EOF. *)
    | Resized of Loop.outcome

  val on_master_readable : t -> event Lwt.t
  (** proxy.md section 3, application-to-terminal: one read from the child's master. Every byte read is written to
      [terminal_out] unchanged and published as a {!Tessera_proxy_observer.Record.traffic} record before the same bytes
      are ingested; a decode/ingest failure never delays or alters the relay that already happened. Every
      {!Tessera.Effect.observation} the ingest emits is published as a {!Tessera_proxy_observer.Record.effect}. *)

  val on_terminal_readable : t -> event Lwt.t
  (** proxy.md section 3, terminal-to-application: one read from [terminal_in], relayed verbatim to the child's master
      and published as a {!Tessera_proxy_observer.Record.traffic} record. Never ingested. *)

  val on_wakeup : t -> event Lwt.t
  (** Drives {!Loop.on_wakeup}. A {!Loop.Resized} outcome publishes one {!Tessera_proxy_observer.Record.resize} record
      (matching the geometry the core just applied) plus one {!Tessera_proxy_observer.Record.effect} per
      {!Tessera.Effect.observation} emitted. A {!Loop.Reported} diagnostic publishes nothing: it is proxy-internal
      operational reporting, not a core observation. Call after {!Loop.wait_for_wakeup} resolves. *)

  val run_master_loop : t -> on_event:(event -> unit) -> unit Lwt.t
  (** Repeatedly calls {!on_master_readable}, invoking [on_event] with every event (so a caller can drive an observer
      server's [note_outcome]/[drain] exactly as it would from a manual dispatch loop), until an {!Application_eof}
      event, at which point the returned promise resolves. *)

  val run_terminal_loop : t -> on_event:(event -> unit) -> unit Lwt.t
  (** Repeatedly calls {!on_terminal_readable}, invoking [on_event] with every event, until a {!Terminal_input_eof}
      event, at which point the returned promise resolves. *)

  val run_relay : t -> on_event:(event -> unit) -> unit Lwt.t
  (** Races {!run_master_loop} against {!run_terminal_loop} and resolves as soon as either one does -- matching the old
      [select]-loop behaviour where the session ended the instant *either* direction reached EOF, without waiting for
      the other. The loser's loop is cancelled (via [Lwt.pick]'s automatic [Lwt.cancel] of every promise in its list
      once one settles), which interrupts its pending [Lwt_unix.read] immediately rather than leaving it registered with
      Lwt's reactor; [on_event] is not called again for the loser. Call this (not
      [Lwt.join [ run_master_loop ...; run_terminal_loop ... ]], which would wait for both and can hang indefinitely
      when only one side ever reaches EOF) from a composition root that exits shortly after this resolves. *)

  val run_resize_loop : t -> on_event:(event -> unit) -> stop:unit Lwt.t -> unit Lwt.t
  (** Repeatedly waits for {!Loop.wait_for_wakeup} and calls {!on_wakeup}, invoking [on_event] with every {!Resized}
      event. Unlike {!run_master_loop}/{!run_terminal_loop}, a resize wake-up source has no EOF of its own, so this loop
      instead runs until [stop] resolves -- pass a promise the composition root resolves once the master or terminal
      loop above has ended the session. *)
end
