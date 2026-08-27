(** Portable, length-delimited binary primitives shared by every checkpoint codec (decoder continuation, renderer state,
    and the outer [Tessera.Checkpoint] envelope). Native OCaml, JSOO, and Melange only: [bytes]/[Buffer.t] in, no
    [Unix], no [Marshal]. *)

type reader
type error = [ `Malformed_varint | `Truncated ]

module E : Err.S with type error = error

val reader : bytes -> reader
(** A cursor over [bytes], starting at offset 0. *)

val at_end : reader -> bool
val remaining : reader -> int
val read_u8 : reader -> (int, error) Err.t
val read_bool : reader -> (bool, error) Err.t

val read_varint : reader -> (int, error) Err.t
(** Unsigned LEB128, bounded to values representable in a native [int]. Suitable for counts, tags, and lengths. *)

val read_varint64 : reader -> (int64, error) Err.t
(** Unsigned LEB128 over the full 64-bit range, for values such as a byte-stream position that can outgrow [int]. *)

val read_bytes : reader -> (bytes, error) Err.t
(** A [read_varint]-prefixed byte string. *)

val read_string : reader -> (string, error) Err.t
(** A [read_varint]-prefixed string. *)

val write_u8 : Buffer.t -> int -> unit
val write_bool : Buffer.t -> bool -> unit
val write_varint : Buffer.t -> int -> unit
val write_varint64 : Buffer.t -> int64 -> unit
val write_bytes : Buffer.t -> bytes -> unit
val write_string : Buffer.t -> string -> unit
val pp_error : Format.formatter -> error -> unit
