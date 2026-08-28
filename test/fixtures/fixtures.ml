let little_endian value = String.init 2 (fun index -> Char.chr ((value lsr (index * 8)) land 0xff))

let compiled_terminfo () =
  let offsets =
    String.init (38 * 2) (fun index ->
        let capability = index / 2 and byte = index mod 2 in
        match (capability, byte) with 5, _ -> '\000' | 10, 0 -> '\005' | 10, _ -> '\000' | _, _ -> '\255')
  in
  Bytes.of_string
    (little_endian 0x11a ^ little_endian 5 ^ little_endian 0 ^ little_endian 0 ^ little_endian 38 ^ little_endian 22
   ^ "demo\000\000" ^ offsets ^ "\027[2J\000\027[%i%p1%d;%p2%dH\000")

let malformed_compiled_terminfo () =
  let offsets = Bytes.make (39 * 2) '\255' in
  Bytes.set offsets (38 * 2) '\001';
  Bytes.of_string
    (little_endian 0x11a ^ little_endian 5 ^ little_endian 0 ^ little_endian 0 ^ little_endian 39 ^ little_endian 1
   ^ "demo\000\000" ^ Bytes.to_string offsets ^ "\000")

let extended_compiled_terminfo () =
  let offsets =
    String.init (38 * 2) (fun index ->
        let capability = index / 2 and byte = index mod 2 in
        match (capability, byte) with 5, _ -> '\000' | _, _ -> '\255')
  in
  (* Extended-capability name offsets are relative to where the name area starts (right after the
     last extended string value's bytes), not to the start of the extended string table the way
     value offsets are: "value\000" occupies the first 6 bytes of the table, so the names "xb"/"xn"/"xs"
     start at relative offsets 0/3/6 within the remaining "xb\000xn\000xs\000". *)
  Bytes.of_string
    (little_endian 0x21e ^ little_endian 5 ^ little_endian 0 ^ little_endian 0 ^ little_endian 38 ^ little_endian 6
   ^ "demo\000\000" ^ offsets ^ "\027[2J\000\000" ^ little_endian 1 ^ little_endian 1 ^ little_endian 1
   ^ little_endian 4 ^ little_endian 15 ^ "\001\000" ^ "\042\000\000\000" ^ little_endian 0 ^ little_endian 0
   ^ little_endian 3 ^ little_endian 6 ^ "value\000xb\000xn\000xs\000")

let malformed_extended_compiled_terminfo () =
  let bytes = extended_compiled_terminfo () in
  Bytes.set bytes 118 '\255';
  Bytes.set bytes 119 '\255';
  bytes
