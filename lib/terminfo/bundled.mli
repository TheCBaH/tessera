(** The release-one bundled [xterm-256color] terminal description (terminal-idea.md "Terminal descriptions and
    terminfo"): what a proxy adapter falls back to when discovering, loading, parsing, or family-selecting the host
    terminal's own terminfo resource fails, or when that resource's capabilities are not consistent with this declared
    family. Parsed through the same public {!Terminfo.parse} path an external resource uses ({!source}), not hand-built
    as a special case, so it shares the same validated {!Description.t} invariants. *)

val name : string
(** ["xterm-256color"], the release-one supported behavioral family and the value a proxy adapter should set as the
    child's [TERM] when falling back -- this is a real, near-universal system terminfo entry name, not a private label,
    since the child process resolves it against its own terminfo database independently of {!description}. *)

val source : string
(** A minimal portable terminfo source definition for {!name} (terminal-idea.md's "portable terminfo source
    definition"), covering exactly the capabilities {!Description.capability} names, with values matching the standard
    system [xterm-256color] terminfo entry. *)

val description : Description.t
(** {!source} parsed under a policy with generous limits. Never fails: {!source} is a small, fixed, valid definition. *)

val is_compatible : Description.t -> bool
(** [true] if [candidate] defines no {!Description.capability} whose value conflicts with {!description}'s value for
    that same capability. A capability {!description} defines that [candidate] leaves unset, or vice versa, is not a
    conflict -- terminfo entries commonly omit capabilities outside their measured subset. This is terminal-idea.md's
    "declared behavioral family... consistent with it" check: it authorizes treating [candidate] as safe to advertise to
    the PTY-side application in place of {!description}, it is not an identity/name comparison. *)
