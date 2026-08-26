(** The real Linux binding of {!Tessera_proxy_platform.Platform.S}: openpty/fork/exec, [TIOCGWINSZ]/[TIOCSWINSZ], and a
    blocked-signal + [signalfd] resize wake-up (proxy.md sections 1-2). Built and enabled only on Linux
    ([lib/proxy_platform/dune]'s [(enabled_if (= %{system} linux))]).

    Callers must never call {!Sys.signal} for [SIGWINCH] anywhere in the same process: the first call to {!spawn} or
    {!resize_wakeup_fd} blocks it process-wide (in the calling thread; this binding must not be used from a program that
    creates OS threads before that first call) so it can only ever be observed through {!resize_wakeup_fd}, never
    through OCaml's own deferred signal-handler dispatch. *)

include Tessera_proxy_platform.Platform.S
