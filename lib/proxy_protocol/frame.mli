(** The observer wire protocol (milestones.md "observable proxy service"): a versioned, length-delimited encoding of
    {!Tessera_proxy_observer.Record.t}, plus an authoritative snapshot/authority preamble and an explicit gap
    notification, so a local socket client can reconstruct the true record interleaving without depending on
    {!Tessera_proxy_observer}'s in-process OCaml types. This module is pure OCaml: it depends on [tessera] and
    [tessera_proxy_observer] for the value types it encodes, but touches no descriptor, socket, or C stub -- the
    transport (a Unix-domain socket server) is a separate, proxy-composition-root concern.

    Deviation from terminal-plan.md's original dependency table: that document names a FlatBuffers
    [tessera_observer.fbs] schema for this role. No FlatBuffers OCaml runtime is wired into this repository yet (only
    [lib/foundation/wire.ml]'s portable LEB128/length-prefixed primitives, added for milestone 6's checkpoint codec).
    Introducing a FlatBuffers dependency purely for this increment would be a large, separate dependency-surface
    decision; this module instead reuses {!Tessera_foundation.Wire} for consistency with the checkpoint codec's
    established style (tagged, length-delimited fields; typed rejection of an unknown version, a truncated length, or a
    malformed tag). A future migration to FlatBuffers, if still desired, is a wire-format change behind this same module
    boundary, not a redesign of the callers in [lib/proxy_linux].

    Deliberately out of scope for release one, per terminal-plan.md's "Proxy organisation": there is no client-to-server
    message in this schema at all. A client is purely a passive stream reader; it cannot request a specific cursor,
    inject terminal input, or otherwise influence the relay. Every connection starts from a fresh authoritative snapshot
    decided by the server, never a client-supplied resume position. *)

type error =
  [ `Malformed of string  (** A field's value could not be interpreted (bad tag, invalid geometry, invalid UTF-8). *)
  | `Unknown_kind of int  (** A frame's leading tag byte does not name a known {!t} constructor. *)
  | `Unknown_version of int  (** The one-time stream preamble named a protocol version this module does not speak. *)
  | `Wire of Tessera_foundation.Wire.error ]

module E : Err.S with type error = error

val current_version : int
(** Sent once, as the very first byte a server writes to a newly accepted connection, before any frame. A client that
    reads a different value must close the connection without attempting to parse further bytes as frames. *)

module Authority : sig
  (** Policy/authority metadata a client needs to interpret every {!Snapshot.t} and geometry it receives -- the declared
      behavioural family, the bounds a conforming geometry must fall within, and the declared reflow mode. Sent once, as
      part of every {!t} that carries a fresh snapshot (release one has no separate "hello" record: a client's first
      frame is always an {!Authoritative_snapshot}). *)

  type t = {
    family : Tessera_foundation.Policy.profile;
    max_columns : Tessera_foundation.UInt.t;
    max_rows : Tessera_foundation.UInt.t;
    reflow : [ `No_reflow ];
        (** Fixed for release one, matching terminal-plan.md's no-reflow scope; carried explicitly (not merely implied
            by the absence of a reflow record) so a future reflow-capable server version can still interoperate with
            this same frame shape by changing only this field's meaning. *)
  }

  val make : policy:Tessera_foundation.Policy.t -> t
  val pp : Format.formatter -> t -> unit
end

module Snapshot : sig
  (** The canonical logical projection a fresh observer needs, deliberately scoped to the same content tests.md's
      deterministic-layer "golden representation" already treats as authoritative: geometry, active screen, cursor,
      title, visibility, and a row-major grid of blank/glyph/wide-continuation cells. Style/colour and provenance (line
      identity, renderer generation/lineage) are intentionally not part of this wire shape: an external observer renders
      or logs what is on screen, it does not resume or fork a {!Tessera.session}, which is what [Tessera.Checkpoint] (a
      separate, portable-core concern) already exists for. *)

  type t = {
    active : Tessera_foundation.Types.screen;
    cells : Tessera_model.Cell.contents array;  (** Row-major, exactly [rows * columns] entries. *)
    cursor : Tessera_foundation.Types.coord;
    cursor_visible : bool;
    position : int;
        (** {!Tessera_proxy_observer.Ring.cursor_to_int} of the cursor a client should read forward from. *)
    size : Tessera_foundation.Types.Size.t;
    title : string option;
  }

  val of_outcome : position:int -> Tessera.outcome -> t
  val pp : Format.formatter -> t -> unit
end

module Pixels : sig
  type unit_ = Device_pixels | Css_pixels | Unspecified
  type t = { width : int; height : int; unit_ : unit_ }

  val pp : Format.formatter -> t -> unit
end

type traffic = { sequence : int; direction : Tessera_foundation.Types.direction; bytes : Bytes.t }
type resize = { sequence : int; size : Tessera_foundation.Types.Size.t; pixels : Pixels.t option }
type effect_observation = { sequence : int; item : Tessera_model.Effect.observation }

type t =
  | Authoritative_snapshot of Authority.t * Snapshot.t
  | Traffic of traffic
  | Resize of resize
  | Effect of effect_observation
  | Gap of { skipped : int; resume : int }
      (** [skipped] is the number of positions between the client's last known position and [resume], regardless of
          whether the gap was detected as a {!Tessera_proxy_observer.Ring.Gap} (the ring itself overwrote unread
          records) or as a transport-level decision to stop buffering for a slow client -- both are the same
          client-visible fact: "resynchronise; you missed [skipped] position(s)." A {!Gap} frame is always immediately
          followed by a fresh {!Authoritative_snapshot} in this protocol's actual usage (see [Observer_server]); it is
          still its own frame so a client can log/count the drop before the snapshot arrives. *)

val of_record : Tessera_proxy_observer.Record.t -> t

val encode : Buffer.t -> t -> unit
(** Appends one length-delimited, self-describing frame. Does not write {!current_version}; a transport writes that once
    per connection via {!write_preamble}. *)

val write_preamble : Buffer.t -> unit
(** Writes the one-time {!current_version} byte a transport sends before any frame. *)

type reader
(** An incremental, chunk-boundary-agnostic parser for a byte stream carrying one {!write_preamble} followed by any
    number of {!encode}d frames -- the shape every connection sends. Mirrors {!Tessera_decoder.Decoder}'s own
    continuation style (named [reader] for the same reason {!Tessera_foundation.Wire}'s cursor is: bounded internal
    buffering only, no assumption about how the transport chunks reads). *)

val reader : unit -> reader
(** Expects {!current_version} as the first byte fed to it. *)

val feed : reader -> bytes -> off:int -> len:int -> (reader * t list, error) result
(** Consumes [len] bytes of [bytes] starting at [off]. Returns every complete frame decoded so far (the preamble, once
    matched, produces no [t]) and a continuation holding any incomplete trailing bytes. An error is terminal: the caller
    must stop feeding this reader and close the connection. *)

val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
