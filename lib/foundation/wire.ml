type reader = { bytes : bytes; mutable pos : int }
type error = [ `Malformed_varint | `Truncated ]

let pp_error ppf = function
  | `Malformed_varint -> Format.pp_print_string ppf "malformed varint"
  | `Truncated -> Format.pp_print_string ppf "truncated"

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let reader bytes = { bytes; pos = 0 }
let remaining reader = Bytes.length reader.bytes - reader.pos
let at_end reader = remaining reader = 0

let read_u8 reader =
  if remaining reader < 1 then E.fail `Truncated
  else
    let value = Char.code (Bytes.get reader.bytes reader.pos) in
    reader.pos <- reader.pos + 1;
    Ok value

let read_bool reader = Result.map (fun value -> value <> 0) (read_u8 reader)

(* Unsigned LEB128 over at most 9 groups of 7 bits: 63 bits, the widest value a non-negative OCaml [int] or an
   always-non-negative [int64] can hold on every backend this project targets. *)
let max_groups = 9

let read_varint64 reader =
  let rec loop shift acc groups =
    if groups = max_groups then E.fail `Malformed_varint
    else
      match read_u8 reader with
      | Error _ as error -> error
      | Ok byte ->
          let acc = Int64.logor acc (Int64.shift_left (Int64.of_int (byte land 0x7f)) shift) in
          if byte land 0x80 = 0 then Ok acc else loop (shift + 7) acc (groups + 1)
  in
  loop 0 0L 0

let read_varint reader =
  match read_varint64 reader with
  | Error _ as error -> error
  | Ok value ->
      if Int64.compare value (Int64.of_int max_int) > 0 then E.fail `Malformed_varint else Ok (Int64.to_int value)

let read_bytes reader =
  match read_varint reader with
  | Error _ as error -> error
  | Ok length ->
      if length < 0 || remaining reader < length then E.fail `Truncated
      else
        let value = Bytes.sub reader.bytes reader.pos length in
        reader.pos <- reader.pos + length;
        Ok value

let read_string reader = Result.map Bytes.unsafe_to_string (read_bytes reader)
let write_u8 buffer value = Buffer.add_char buffer (Char.chr (value land 0xff))
let write_bool buffer value = write_u8 buffer (if value then 1 else 0)

let write_varint64 buffer value =
  let rec loop value =
    let byte = Int64.to_int (Int64.logand value 0x7fL) in
    let rest = Int64.shift_right_logical value 7 in
    if Int64.equal rest 0L then write_u8 buffer byte
    else (
      write_u8 buffer (byte lor 0x80);
      loop rest)
  in
  loop value

let write_varint buffer value = write_varint64 buffer (Int64.of_int value)

let write_bytes buffer value =
  write_varint buffer (Bytes.length value);
  Buffer.add_bytes buffer value

let write_string buffer value = write_bytes buffer (Bytes.unsafe_of_string value)
