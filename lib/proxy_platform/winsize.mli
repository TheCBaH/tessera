(** A raw PTY window size (proxy.md section 1): the columns/rows an ioctl actually reported, which may be zero -- a
    real, observable result (e.g. before a host terminal has ever been sized), not something the platform boundary is
    allowed to reject or fabricate around. {!size} is the one place that turns this into validated core geometry, and is
    expected to fail exactly when the resize protocol (proxy.md section 2 step 2) must report an unmodelled-resize
    diagnostic instead of calling [Unix_adapter.resize].

    The optional pixel extent is tagged with the unit it was measured in. Pixel fields are proxy metadata; they are
    never part of {!Tessera_foundation.Types.Size.t} and never reach the renderer. *)

type pixel_unit = Device_pixels | Css_pixels | Unspecified
type pixels = { width : int; height : int; unit : pixel_unit }
type t

val make : columns:Tessera_foundation.UInt.t -> rows:Tessera_foundation.UInt.t -> pixels:pixels option -> t
val columns : t -> Tessera_foundation.UInt.t
val rows : t -> Tessera_foundation.UInt.t
val pixels : t -> pixels option

val size : t -> (Tessera_foundation.Types.Size.t, Tessera_foundation.Types.error) Err.t
(** Validates {!columns}/{!rows} as core geometry. Fails exactly when either is zero: the raw, unmodelled result {!make}
    is required to be able to represent. *)

val same_geometry : t -> t -> bool
(** Compares raw {!columns}/{!rows} directly, not the validated {!size} -- this is the resize protocol's
    distinct-vs-same-size comparison (proxy.md section 2 step 3), which runs after validity has already been checked
    separately (step 2) and must still work when one side is a previously-applied, already-valid value and the other has
    not yet been validated. Pixel metadata never participates. *)

val pp : Format.formatter -> t -> unit
val pp_pixels : Format.formatter -> pixels -> unit
val pp_pixel_unit : Format.formatter -> pixel_unit -> unit
