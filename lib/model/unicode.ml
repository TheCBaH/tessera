type scalar = Uchar.t
type grapheme = scalar list
type decoder_continuation = { pending : scalar list; segmenter : Uuseg.t }
type error = [ `Invalid_utf8 | `Unicode_limit_exceeded ]
type width = One | Two | Zero

let pp_error ppf = function
  | `Invalid_utf8 -> Format.pp_print_string ppf "invalid UTF-8"
  | `Unicode_limit_exceeded -> Format.pp_print_string ppf "unicode limit exceeded"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let ( let* ) = Result.bind
let pp_scalar ppf scalar = Format.fprintf ppf "U+%04X" (Uchar.to_int scalar)

let pp_grapheme ppf grapheme =
  Format.fprintf ppf "<%a>" (Format.pp_print_list ~pp_sep:(fun _ () -> ()) pp_scalar) grapheme

let utf8 grapheme =
  let buffer = Buffer.create 32 in
  List.iter (Uutf.Buffer.add_utf_8 buffer) grapheme;
  Buffer.contents buffer

module Grapheme_sequence = struct
  type t = grapheme list

  let empty = []
  let append = ( @ )
  let fold_left = List.fold_left
  let singleton value = [ value ]
  let utf8 value = String.concat "" (List.map utf8 value)

  let pp ppf value =
    Format.fprintf ppf "[%a]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_grapheme)
      value
end

let initial = { pending = []; segmenter = Uuseg.create `Grapheme_cluster }
let grapheme_of_scalar scalar = [ scalar ]
let scalars (grapheme : grapheme) = grapheme
let of_scalars scalars : grapheme = scalars
let pending continuation = List.rev continuation.pending

(* [continuation.pending] holds the scalars of the grapheme cluster still open at a boundary decision: grapheme
   cluster break rules (UAX #29) never reach back across a completed boundary, so a fresh segmenter replayed with
   just this open prefix reaches a state equivalent to the persisted one. This lets a checkpoint restore the
   otherwise-opaque [Uuseg.t] automaton from a small, policy-bounded scalar list instead of the segmenter itself. *)
let of_pending scalars =
  let segmenter = Uuseg.create `Grapheme_cluster in
  (* [Uuseg.add] only accepts a fresh external input once it has fully drained the previous one down to [`Await]:
     each [`Boundary]/[`Uchar] response must be followed by re-adding [`Await] until the automaton is ready again,
     exactly as {!segment} does for a live feed. *)
  let rec drain input =
    match Uuseg.add segmenter input with `Await | `End -> () | `Boundary | `Uchar _ -> drain `Await
  in
  List.iter (fun scalar -> drain (`Uchar scalar)) scalars;
  { pending = List.rev scalars; segmenter }

let pending_limit policy =
  Tessera_foundation.UInt.to_int (Tessera_foundation.Limits.max_control_bytes (Tessera_foundation.Policy.limits policy))

let flush pending result = match pending with [] -> result | _ -> List.rev pending :: result

let segment ~limit segmenter pending input =
  let rec loop pending result input =
    match Uuseg.add segmenter input with
    | `Await -> Ok (pending, result)
    | `Boundary -> loop [] (flush pending result) `Await
    | `End -> Ok (pending, result)
    | `Uchar scalar ->
        if List.length pending = limit then E.fail `Unicode_limit_exceeded else loop (scalar :: pending) result `Await
  in
  loop pending [] input

let feed policy continuation scalar =
  let segmenter = Uuseg.copy continuation.segmenter in
  let* pending, result = segment ~limit:(pending_limit policy) segmenter continuation.pending (`Uchar scalar) in
  Ok ({ pending; segmenter }, List.rev result)

let finish policy continuation =
  let segmenter = Uuseg.copy continuation.segmenter in
  let* pending, result = segment ~limit:(pending_limit policy) segmenter continuation.pending `End in
  Ok (List.rev (flush pending result))

let pp_decoder_continuation ppf { pending; _ } =
  match pending with
  | [] -> Format.pp_print_string ppf "empty"
  | pending -> Format.fprintf ppf "pending(%a)" pp_grapheme (List.rev pending)

let pp_width ppf = function
  | One -> Format.pp_print_string ppf "one"
  | Two -> Format.pp_print_string ppf "two"
  | Zero -> Format.pp_print_string ppf "zero"

let width grapheme =
  let scalar_width scalar =
    if Uucp.Emoji.is_emoji scalar then 2
    else match Uucp.Break.tty_width_hint scalar with 2 -> 2 | 1 -> 1 | 0 | -1 -> 0 | _ -> assert false
  in
  match List.fold_left (fun maximum scalar -> max maximum (scalar_width scalar)) 0 grapheme with
  | 0 -> Zero
  | 1 -> One
  | 2 -> Two
  | _ -> assert false
