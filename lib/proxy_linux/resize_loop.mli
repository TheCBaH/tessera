(** The resize protocol (proxy.md section 2), generic over {!Tessera_proxy_platform.Platform.S} so it can be tested
    against a fake implementation with no real PTY, child process, or signal. *)

module Make (Platform : Tessera_proxy_platform.Platform.S) : sig
  type t
  (** The mutable state a live resize loop needs: the platform's [pty], the {!Tessera_lwt.Lwt_adapter.t} it drives, and
      the geometry most recently applied to the child. *)

  type diagnostic =
    | Physical_query_failed of Platform.error
        (** Step 1: querying the physical terminal failed. Both the child PTY and the renderer are left at their last
            known values. *)
    | Unmodelled_resize of { columns : Tessera_foundation.UInt.t; rows : Tessera_foundation.UInt.t }
        (** Step 2: the queried size had a zero/invalid row or column. The raw value was still applied to the child PTY
            when possible, but no {!Tessera_lwt.Lwt_adapter.resize} call was made. *)
    | Set_winsize_failed of Platform.error
        (** Step 3 (distinct size): applying the new size to the child PTY failed; no {!Tessera_lwt.Lwt_adapter.resize}
            call was made either, since the geometry actually reaching the child could not be confirmed. *)
    | Notify_unchanged_failed of Platform.error
        (** Step 3 (same size): re-notifying the child's foreground process group failed; no
            {!Tessera_lwt.Lwt_adapter.resize} call was made. *)
    | Adapter_resize_failed of Tessera_lwt.Lwt_adapter.error Err.Error.t
        (** Step 4: the child PTY was updated, but {!Tessera_lwt.Lwt_adapter.resize} itself failed. *)

  type outcome =
    | Resized of Tessera.outcome  (** Step 4 ran and the core accepted the resize. *)
    | Reported of diagnostic  (** No core resize was performed; see {!diagnostic} for why. *)

  type error =
    [ `Initial_query_failed of Platform.error
    | `Invalid_initial_size of Tessera_foundation.Types.error Err.Error.t
    | `Spawn_failed of Platform.error ]

  val pp_diagnostic : Format.formatter -> diagnostic -> unit
  val pp_error : Format.formatter -> error -> unit

  val startup :
    argv:string array ->
    env:string array ->
    lineage_id:Tessera_foundation.Lineage_id.t ->
    policy:Tessera_foundation.Policy.t ->
    (t, error) result
  (** proxy.md section 2 "Startup": queries {!Platform.physical_winsize}, validates it, spawns the child with [env] as
      its environment and that value as [initial_winsize], then creates the adapter with the same validated size. No
      [Out_of_band (Resize _)] is ingested for the initial size: {!Tessera_lwt.Lwt_adapter.create} already establishes
      it. Synchronous in both the platform and the adapter, so this remains an ordinary [result], not an [Lwt.t]. *)

  val pty : t -> Platform.pty
  val adapter : t -> Tessera_lwt.Lwt_adapter.t

  val last_applied : t -> Tessera_proxy_platform.Winsize.t
  (** The raw winsize most recently applied to the child PTY (including pixel metadata, when reported) -- what
      {!Resized} outcomes' geometry, and any {!Tessera_proxy_observer.Record.resize} a caller publishes for one, should
      be derived from. *)

  val wait_for_wakeup : t -> unit Lwt.t
  (** Resolves once {!Platform.resize_wakeup_fd} is readable. A caller loops this itself (see
      {!Session.run_resize_loop}) rather than this module driving its own loop, so the exact interleaving against the
      master/terminal loops is the composition root's decision, not this module's. *)

  val on_wakeup : t -> outcome Lwt.t
  (** proxy.md section 2 "On resize_wakeup_fd readable": drains the wake-up descriptor (reads until it would block),
      then runs steps 1-4 as {!requery}. Call after {!wait_for_wakeup} resolves. *)

  val requery : t -> outcome Lwt.t
  (** proxy.md section 2 "Lifecycle re-query points": runs steps 1-4 without an actual wake-up having fired -- used at
      resume after suspension, terminal reattachment, and immediately before resuming a paused relay. *)
end
