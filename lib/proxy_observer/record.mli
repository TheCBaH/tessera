(** The observer schema (proxy.md section 4): traffic, resize, and effect records sharing one monotonically increasing
    sequence, so an observer can recover the true interleaving of all three kinds, not just each kind's own sub-order.
    This module is pure OCaml: it depends on [tessera] for {!Tessera.Effect.observation} and geometry types, but touches
    no descriptor, signal, or C stub. *)

type sequence
(** Monotonically increasing per {!Ring.t} (proxy.md: "per proxy session"); never reset except by a new lineage, i.e. a
    fresh {!Ring.t}. Minted only by {!Ring.next_sequence}. *)

val pp_sequence : Format.formatter -> sequence -> unit
val compare_sequence : sequence -> sequence -> int

val initial_sequence : sequence
(** The first sequence a fresh {!Ring.t} mints. *)

val next_sequence : sequence -> sequence
(** The sequence after [sequence]. {!Ring.next_sequence} is the only intended caller; kept here, not on {!Ring.t}, so
    {!sequence} stays abstract even from [Ring]. *)

val sequence_to_int : sequence -> int
(** The wire representation a protocol codec (e.g. [Tessera_proxy_protocol]) needs to encode a record's position;
    [sequence] stays otherwise abstract so no caller can synthesise or compare one across an unrelated {!Ring.t}. *)

val sequence_of_int : int -> sequence
(** The inverse of {!sequence_to_int}: reconstructs the sequence a proxy checkpoint envelope persisted, so
    {!Ring.create}'s [~start_position] can resume numbering after it rather than restarting at {!initial_sequence}.
    Raises [Invalid_argument] if [n] is negative -- a caller must validate untrusted/decoded data itself before calling
    this, the same way {!Ring.create} treats a non-positive capacity as a caller-contract violation rather than a typed
    error. *)

(* Not part of proxy.md's sketch: pixel metadata never reaches [Tessera_foundation.Types.Size.t], but
   this package cannot depend on [tessera_proxy_platform]'s [Winsize.pixels] (proxy.md's package
   layout: only [tessera_proxy_linux] may depend on both platform and observer packages together), so
   the observer-facing shape is declared independently here. A composition root (e.g.
   [tessera_proxy_linux/session.ml]) converts [Winsize.pixels] into this shape when publishing a
   {!resize} record. *)
module Pixels : sig
  type pixel_unit = Device_pixels | Css_pixels | Unspecified
  type t = { width : int; height : int; unit : pixel_unit }

  val pp : Format.formatter -> t -> unit
  val pp_pixel_unit : Format.formatter -> pixel_unit -> unit
end

type traffic = { sequence : sequence; direction : Tessera_foundation.Types.direction; bytes : Bytes.t }
type resize = { sequence : sequence; size : Tessera_foundation.Types.Size.t; pixels : Pixels.t option }
type effect_observation = { sequence : sequence; item : Tessera.Effect.observation }
type t = Traffic of traffic | Resize of resize | Effect of effect_observation

val traffic : sequence:sequence -> direction:Tessera_foundation.Types.direction -> bytes:Bytes.t -> t
val resize : sequence:sequence -> size:Tessera_foundation.Types.Size.t -> pixels:Pixels.t option -> t
val effect_observation : sequence:sequence -> item:Tessera.Effect.observation -> t
val sequence : t -> sequence
val pp : Format.formatter -> t -> unit
