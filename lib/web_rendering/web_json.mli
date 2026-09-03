(** JSON envelopes for {!Web_html.t}/{!Web_canvas.t}, via [Jsont]/[Jsont_bytesrw] ([Jsont_brr] is unavailable to
    Melange, so this codec is built on the vendored [tessera_jsont]/[tessera_bytesrw]/[tessera_jsont_bytesrw] libraries
    instead of an opam dependency). Every envelope carries a literal [schema]/[version]/[target] (["html"] or
    ["canvas"]), a [meta] block (frame kind, active screen, geometry, generation, lineage, title), and the typed
    payload. [generation]/[lineage_id] are each the canonical, non-negative decimal encoding of their respective
    {!Tessera_foundation.Generation.t}/{!Tessera_foundation.Lineage_id.t} ([Tessera_foundation.UInt.pp]'s output --
    digits only, no sign, no leading zero unless the whole string is ["0"]), safe for any consumer to parse as an
    arbitrary-precision integer and compare numerically. This is not just a convention: the codec itself enforces it --
    decoding a [generation]/[lineage_id] that isn't in this form is a decode error, and encoding an envelope whose
    [meta] carries one that isn't is an encode error (see [validate_meta]-shaped behaviour on [encode_html_frame]/
    [encode_canvas_frame] below), so a hand-built envelope can never bypass this promise the way a plain [Jsont.string]
    mapping would let it. [generation] is comparable numerically *within* one lineage (monotonically increasing there);
    [lineage_id] is only guaranteed strictly increasing across successive bridge instances a caller creates for the same
    conceptual session (a caller convention this module has no way to enforce, since it has no notion of "the previous
    bridge") and is not otherwise comparable across unrelated sessions.

    Decoding enforces [schema]/[version]/[target] against the expected constants (an unsupported or mismatched wire
    frame is a decode error, never silently accepted), and validates every decoded {!Web_html.color_value}/CSS class
    against the exact closed set {!Web_html.of_frame} ever produces, so {!Web_html.to_html} never has to render
    attacker-controlled CSS variable names, hex strings, or class names. *)

type geometry = { columns : int; rows : int }

type meta = {
  kind : Web_frame.kind;
  active : Tessera_foundation.Types.screen;
  geometry : geometry;
  generation : string;
  lineage_id : string;
  title : string option;
}

type html_envelope = { schema : string; version : int; target : string; meta : meta; frame : Web_html.t }
type canvas_envelope = { schema : string; version : int; target : string; meta : meta; frame : Web_canvas.t }

val schema : string
val version : int
val html_target : string
val canvas_target : string
val html_envelope_of : Web_frame.t -> html_envelope
val canvas_envelope_of : Web_frame.t -> canvas_envelope

type error = [ `Json of string ]

module E : Err.S with type error = error

val encode_html_frame : html_envelope -> (string, error) Err.t
val decode_html_frame : string -> (html_envelope, error) Err.t
val encode_canvas_frame : canvas_envelope -> (string, error) Err.t
val decode_canvas_frame : string -> (canvas_envelope, error) Err.t
