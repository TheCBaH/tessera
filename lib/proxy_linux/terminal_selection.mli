(** terminal-idea.md "Terminal descriptions and terminfo", the proxy's deliberate terminal selection: discover-and-parse
    the host's own declared terminal type, or fall back to the bundled [xterm-256color] definition and advertise that
    fallback to the PTY-side application. [locate]/[read] are injected so this stays testable the way the rest of this
    package tests against a fake platform, without touching the real filesystem; a real caller passes
    {!Tessera_proxy_platform.Terminfo_resource.locate}/[read]. *)

type t = private {
  description_identity : string option;
      (** {!Tessera.Description.identity} of the description actually selected -- {!Tessera.Bundled.name} when
          [fallback] is [true]. *)
  child_term : string;  (** The [TERM] value to advertise to the PTY-side application, i.e. the child process. *)
  fallback : bool;  (** [true] if {!Tessera.Bundled.description} was used in place of a discovered resource. *)
}

val select :
  policy:Tessera_foundation.Policy.t ->
  term:string option ->
  locate:(term:string -> string option) ->
  read:(string -> (bytes, [ `Read_failed of string ]) result) ->
  t
(** [term] is the host's advertised terminal type ([$TERM]), or [None] if it declared none. Selection: locate a terminfo
    resource for [term], read it, parse it, and check {!Tessera.Bundled.is_compatible} on the result. Any step being
    absent or failing -- no [term], [locate] returns [None], [read] fails, parsing fails, or the parsed description is
    not compatible -- falls back to {!Tessera.Bundled.description}/{!Tessera.Bundled.name}. Never fails itself: a
    discovery/parse failure is exactly the documented fallback path, not an error to propagate. *)

val terminfo_dirs_of_env : string option -> string list
(** Parses [$TERMINFO_DIRS] ([None] if unset) into the ordered list of directories {!select}'s [locate] should search,
    following ncurses' colon-separated semantics: an empty element (leading, trailing, or between two colons) stands for
    [/etc/terminfo] at that exact position, rather than being dropped. *)

val env_with_term : string array -> child_term:string -> string array
(** [base] with any existing [TERM=...] entry replaced by [child_term] (or [TERM=<child_term>] appended if [base] has
    none). Every other entry of [base] is preserved verbatim and in place. *)
