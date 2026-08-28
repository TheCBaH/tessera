(** The Linux proxy's terminfo discovery adapter (terminal-idea.md: "asks its platform adapter to locate the
    corresponding terminfo resource"). Resource discovery is deliberately outside the pure {!Tessera_terminfo} parser;
    this module supplies it for the proxy composition root, but only touches the filesystem behind explicit,
    caller-supplied search inputs -- no hidden {!Sys.getenv} -- so it stays testable against a temporary directory tree
    the way the rest of this package tests against a fake platform. *)

type error = [ `Read_failed of string ]

val pp_error : Format.formatter -> error -> unit

val default_search_dirs : string list
(** The compiled-in ncurses default search path on most Linux distributions, applied after every caller-supplied
    directory: [/etc/terminfo]; [/lib/terminfo]; [/usr/share/terminfo]. *)

val locate : term:string -> home:string option -> terminfo:string option -> terminfo_dirs:string list -> string option
(** The ncurses terminfo search order for [term]: [terminfo] ([$TERMINFO]) first; then [home]/[.terminfo]
    ([$HOME/.terminfo]); then each of [terminfo_dirs] ([$TERMINFO_DIRS], colon-split, in order); then each of
    {!default_search_dirs}. Every directory, including [terminfo] and [home]/[.terminfo], is checked at
    [<dir>/<first character of term>/<term>], the common single-directory-tree hashed layout -- the alternate scheme
    some installations use for a small set of non-alphanumeric first characters is not implemented. Returns the first
    candidate path that names a regular file, or [None] if every candidate is absent. *)

val read : string -> (bytes, error) result
(** Reads the file at the given path into memory in full. *)
