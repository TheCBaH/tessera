module Terminfo = Tessera_terminfo
open Tessera_test_support.Support

let small_policy =
  match policy ~max_control_bytes:32 ~max_csi_params:4 ~max_diagnostics:4 ~max_snapshot_cells:64 () with
  | Ok value -> value
  | Error message -> failwith message

let parse_compiled raw = Terminfo.Terminfo.parse small_policy (Terminfo.Terminfo.Compiled (Bytes.of_string raw))
let parse_source raw = Terminfo.Terminfo.parse small_policy (Terminfo.Terminfo.Source raw)

let () =
  Crowbar.add_test ~name:"compiled terminfo parser never raises on arbitrary bytes" [ Crowbar.bytes ] (fun raw ->
      match parse_compiled raw with Ok _ | Error _ -> ())

let () =
  Crowbar.add_test ~name:"terminfo source parser never raises on arbitrary text" [ Crowbar.bytes ] (fun raw ->
      match parse_source raw with Ok _ | Error _ -> ())

let little_endian value = String.init 2 (fun index -> Char.chr ((value lsr (index * 8)) land 0xff))

(* A structurally-plausible compiled header (correct magic, arbitrary size/count fields) followed by
   arbitrary tail bytes, so the fuzzer spends most of its budget inside the offset/alignment/checked-
   arithmetic validation of the name/boolean/number/string tables instead of always failing the very
   first magic-number check the way uniformly random bytes almost always do. *)
let header_gen =
  Crowbar.map
    [
      Crowbar.choose [ Crowbar.const 0x11a; Crowbar.const 0x21e ];
      Crowbar.range 0x10000;
      Crowbar.range 0x10000;
      Crowbar.range 0x10000;
      Crowbar.range 0x10000;
      Crowbar.range 0x10000;
      Crowbar.bytes;
    ]
    (fun magic names_size boolean_count number_count string_count string_size tail ->
      little_endian magic ^ little_endian names_size ^ little_endian boolean_count ^ little_endian number_count
      ^ little_endian string_count ^ little_endian string_size ^ tail)

let () =
  Crowbar.add_test ~name:"compiled terminfo parser never raises on a plausible header with arbitrary tail bytes"
    [ header_gen ] (fun raw -> match parse_compiled raw with Ok _ | Error _ -> ())
