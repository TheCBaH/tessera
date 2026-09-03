(** The [tessera.proxy-web] control-channel wire protocol: the small JSON envelope exchanged over a browser's WebSocket
    session with [tessera-proxy], independent of and versioned
    separately from [tessera.web-frame] ({!Tessera_web_rendering.Web_json}, the payload the same connection also
    streams). Pure OCaml, no Lwt/Unix/socket: the transport ({!Tessera_proxy_linux.Web_server}) owns framing and I/O,
    this only encodes/decodes one already-assembled JSON text message at a time.

    {2 Message shapes}

    A client message always carries its own [id]: a client-chosen correlation token the server echoes back verbatim in
    exactly one reply, never allocated or tracked by the server itself -- the WebSocket connection is the identity, [id]
    is only for the client's own bookkeeping.

    A server {!Error} carries [id : string option]: [Some] echoes a specific, successfully-decoded client command that
    was itself invalid for some other reason (e.g. a second {!Hello} on an already-attached connection); [None] (wire
    [null]) is a connection-level failure where no client [id] was ever successfully decoded at all (malformed JSON, an
    unknown [schema]/[version]/[type], or a raw-frame-level violation the transport detects before any JSON is even
    assembled). *)

type target = Html | Canvas
type capabilities = { observe : bool; input : bool; resize : bool }
type client_message = Hello of { id : string; target : target } | Resync of { id : string } | Close of { id : string }

type server_message =
  | Ready of { id : string; capabilities : capabilities }
  | Result of { id : string }
  | Error of { id : string option; message : string }

type error =
  [ `Json of string
    (** Malformed JSON, invalid UTF-8, or a structurally invalid envelope (a missing/mistyped field, or a message type
        disagreeing with which fields accompany it). *)
  | `Oversize  (** The input exceeds the caller-supplied [max_bytes] bound; never parsed at all. *)
  | `Unknown_schema of string
  | `Unknown_type of string
    (** A well-formed envelope whose [schema]/[version] matched, but whose [type] names no known message. *)
  | `Unknown_version of int ]

module E : Err.S with type error = error

val schema : string
(** ["tessera.proxy-web"]. *)

val version : int
(** [1]. *)

val encode_client_message : client_message -> string
(** Minified JSON. Always succeeds: every {!client_message} is representable. *)

val decode_client_message : max_bytes:int -> string -> (client_message, error) Err.t
(** Rejects with [`Oversize] without attempting to parse at all when [String.length text > max_bytes] -- callers (the
    transport) must apply this to each already-bounded chunk of accumulated input, not only once after buffering an
    unboundedly large message. *)

val encode_server_message : server_message -> string
(** Minified JSON. Always succeeds: every {!server_message} is representable. *)

val decode_server_message : max_bytes:int -> string -> (server_message, error) Err.t
(** Same bound discipline as {!decode_client_message}. *)

val pp_target : Format.formatter -> target -> unit
val pp_capabilities : Format.formatter -> capabilities -> unit
val pp_client_message : Format.formatter -> client_message -> unit
val pp_server_message : Format.formatter -> server_message -> unit
val pp_error : Format.formatter -> error -> unit
