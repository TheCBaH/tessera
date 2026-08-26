(** The proxy session (proxy.md section 5): a real deployment's mutable state -- a {!Resize_loop.Make} instance (which
    itself owns the {!Tessera_unix.Unix_adapter.t} and [Platform.pty]) plus a {!Tessera_proxy_observer.Ring.t}, and
    nothing else mutable: no raw signal, no bare descriptor readiness flag, no unwrapped winsize. Generic over
    {!Tessera_proxy_platform.Platform.S} so it is testable against a fake platform, the same way {!Resize_loop.Make} is.
*)

module Make (Platform : Tessera_proxy_platform.Platform.S) : sig
  module Loop : module type of Resize_loop.Make (Platform)

  type t

  val create :
    argv:string array ->
    lineage_id:Tessera_foundation.Lineage_id.t ->
    policy:Tessera_foundation.Policy.t ->
    terminal_in:Unix.file_descr ->
    terminal_out:Unix.file_descr ->
    observer_capacity:int ->
    read_buffer_bytes:int ->
    (t, Loop.error) result
  (** [terminal_in]/[terminal_out] are the real terminal's descriptors: application-to-terminal bytes are written
      verbatim to [terminal_out]; terminal-to-application bytes are read from [terminal_in] and relayed verbatim to the
      child, never ingested. *)

  val loop : t -> Loop.t
  val ring : t -> Tessera_proxy_observer.Ring.t

  type event =
    | Application_bytes of Tessera.outcome  (** Application-to-terminal bytes were relayed and successfully ingested. *)
    | Application_ingest_failed of Tessera_unix.Unix_adapter.error Err.Error.t
        (** The bytes were still relayed to the real terminal verbatim; only decoding/ingestion failed. *)
    | Application_eof of Tessera.outcome  (** The child's master reached EOF; {!Tessera.finish} ran. *)
    | Terminal_input_relayed of int  (** [n] bytes were read from [terminal_in] and relayed to the child, verbatim. *)
    | Terminal_input_eof  (** [terminal_in] reached EOF. *)
    | Resized of Loop.outcome

  val on_master_readable : t -> event
  (** proxy.md section 3, application-to-terminal: one read from the child's master. Every byte read is written to
      [terminal_out] unchanged and published as a {!Tessera_proxy_observer.Record.traffic} record before the same bytes
      are ingested; a decode/ingest failure never delays or alters the relay that already happened. Every
      {!Tessera.Effect.observation} the ingest emits is published as a {!Tessera_proxy_observer.Record.effect}. *)

  val on_terminal_readable : t -> event
  (** proxy.md section 3, terminal-to-application: one read from [terminal_in], relayed verbatim to the child's master
      and published as a {!Tessera_proxy_observer.Record.traffic} record. Never ingested. *)

  val on_wakeup : t -> event
  (** Drives {!Loop.on_wakeup}. A {!Loop.Resized} outcome publishes one {!Tessera_proxy_observer.Record.resize} record
      (matching the geometry the core just applied) plus one {!Tessera_proxy_observer.Record.effect} per
      {!Tessera.Effect.observation} emitted. A {!Loop.Reported} diagnostic publishes nothing: it is proxy-internal
      operational reporting, not a core observation. *)

  type ready = Wakeup | Master | Terminal_input

  val select : t -> timeout:float -> ready list
  (** proxy.md section 2 "Ordering against child output", extended to the third descriptor this session adds: the
      wake-up descriptor is always ordered first when ready, ahead of both the master and [terminal_in]. *)
end
