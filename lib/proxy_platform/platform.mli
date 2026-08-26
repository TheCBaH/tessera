(** The Linux proxy platform boundary (proxy.md section 1): a module type, not a concrete module, so the resize protocol
    and the relay loop can be tested against a fake implementation without a real PTY, a real child process, or a real
    signal -- mirroring how [test/conformance]'s [Scenario]/[Reference] decouples ingress ordering from any real
    scheduler.

    Every real implementation must uphold {!section:signal-safety}: [SIGWINCH] is blocked in the process and observed
    only through {!S.resize_wakeup_fd}, drained from the main poll loop. The one statement permitted to run inside an
    actual signal handler, if a self-pipe stands in for [signalfd], is a single async-signal-safe [write] of one byte to
    the pipe's write end; a handler must never allocate, call into the OCaml runtime, run an ioctl, mutate the renderer,
    or publish an observer record. All real work happens after the main loop observes {!S.resize_wakeup_fd} readable,
    never inside signal delivery itself. *)

module type S = sig
  type pty
  (** An open PTY pair (master + slave), with a child already attached to the slave side. *)

  type error

  val pp_error : Format.formatter -> error -> unit

  val spawn : argv:string array -> initial_winsize:Winsize.t -> (pty, error) result
  (** Opens a PTY, forks, execs [argv] on the slave side with the slave as its controlling terminal, and applies
      [initial_winsize] before the child runs. *)

  val master_fd : pty -> Unix.file_descr
  (** The descriptor to read child output from and write terminal input to. Never the slave. *)

  val get_winsize : pty -> (Winsize.t, error) result
  (** [TIOCGWINSZ] on the master. *)

  val set_winsize : pty -> Winsize.t -> (unit, error) result
  (** [TIOCSWINSZ] on the master. The kernel notifies the slave's foreground process group with [SIGWINCH] as a side
      effect exactly when the applied value differs from the previous one; callers must not assume an unconditional
      notification. *)

  val notify_unchanged_winsize : pty -> (unit, error) result
  (** Sends one [SIGWINCH] to the slave's foreground process group directly, for the case documented in proxy.md's
      resize protocol: a host notification whose winsize equals what is already applied, where {!set_winsize} alone
      would not signal the child. *)

  val resize_wakeup_fd : pty -> Unix.file_descr
  (** A descriptor that becomes readable exactly when a host resize notification (the physical terminal's own
      [SIGWINCH], relayed through a blocked-signal + [signalfd] or a self-pipe) has arrived. Readers must drain it (it
      may coalesce several notifications into one readable event) and then call {!physical_winsize} to learn the new
      value -- this descriptor only wakes the loop, it carries no geometry. *)

  val physical_winsize : unit -> (Winsize.t, error) result
  (** [TIOCGWINSZ] on the process's own controlling terminal (fd 0/1/2), i.e. the host side, not the child PTY. *)
end
