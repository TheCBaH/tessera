(* terminal-idea.md "Terminal descriptions and terminfo": the proxy's deliberate terminal selection, exercised
   directly against injected [locate]/[read] functions -- no real filesystem, no real terminfo database, matching how
   the rest of this package tests against a fake platform instead of real Linux state. *)
module Selection = Tessera_proxy_linux.Terminal_selection

let or_fail = function Ok value -> value | Error message -> failwith message
let policy () = or_fail (Tessera_test_support.Support.policy ())
let little_endian value = String.init 2 (fun index -> Char.chr ((value lsr (index * 8)) land 0xff))

(* A minimal legacy-format (magic 0x11a) compiled terminfo blob with exactly the given (standard string capability
   index, value) entries set, every other string offset marked absent -- the same layout test/fixtures/fixtures.ml
   uses, generalized so this module can place values at arbitrary indices matching lib/terminfo/terminfo.ml's
   "known" compiled-index table (Clear_screen=5, Erase_line=6, Cursor_address=10, Cursor_down=11, Cursor_left=14,
   Cursor_right=17, Cursor_up=19, Erase_char=37). *)
let compiled_terminfo entries =
  let name_field = "demo\000" in
  let name_size = String.length name_field in
  let name_padded = if name_size mod 2 = 1 then name_field ^ "\000" else name_field in
  let string_count = 1 + List.fold_left (fun acc (index, _) -> max acc index) 0 entries in
  let table = Buffer.create 64 in
  let offsets = Array.make string_count 0xffff in
  List.iter
    (fun (index, value) ->
      offsets.(index) <- Buffer.length table;
      Buffer.add_string table value;
      Buffer.add_char table '\000')
    entries;
  let offsets_bytes = String.concat "" (Array.to_list (Array.map little_endian offsets)) in
  let string_table = Buffer.contents table in
  Bytes.of_string
    (little_endian 0x11a ^ little_endian name_size ^ little_endian 0 ^ little_endian 0 ^ little_endian string_count
    ^ little_endian (String.length string_table)
    ^ name_padded ^ offsets_bytes ^ string_table)

let bundled_compatible_compiled_terminfo () =
  compiled_terminfo
    [
      (5, "\027[H\027[2J");
      (6, "\027[K");
      (10, "\027[%i%p1%d;%p2%dH");
      (11, "\n");
      (14, "\b");
      (17, "\027[C");
      (19, "\027[A");
      (37, "\027[%p1%dX");
    ]

let incompatible_compiled_terminfo () = compiled_terminfo [ (5, "\027[H\027[J") (* a different clear sequence *) ]

let pp_selection ppf (selection : Selection.t) =
  Format.fprintf ppf "fallback=%b child_term=%s identity=%a" selection.fallback selection.child_term
    (Format.pp_print_option Format.pp_print_string)
    selection.description_identity

let never_locate ~term:_ = None
let never_read _ = Error (`Read_failed "never called")

let%expect_test "no $TERM at all falls back without ever calling locate" =
  let selection = Selection.select ~policy:(policy ()) ~term:None ~locate:never_locate ~read:never_read in
  Format.printf "%a@." pp_selection selection;
  [%expect {| fallback=true child_term=xterm-256color identity=xterm-256color |}]

let%expect_test "an undiscoverable terminfo resource falls back" =
  let selection =
    Selection.select ~policy:(policy ()) ~term:(Some "unknown-term") ~locate:(fun ~term:_ -> None) ~read:never_read
  in
  Format.printf "%a@." pp_selection selection;
  [%expect {| fallback=true child_term=xterm-256color identity=xterm-256color |}]

let%expect_test "a located resource that fails to read falls back" =
  let selection =
    Selection.select ~policy:(policy ()) ~term:(Some "demo")
      ~locate:(fun ~term:_ -> Some "/nonexistent/path")
      ~read:(fun _ -> Error (`Read_failed "boom"))
  in
  Format.printf "%a@." pp_selection selection;
  [%expect {| fallback=true child_term=xterm-256color identity=xterm-256color |}]

let%expect_test "a located resource that fails to parse falls back" =
  let selection =
    Selection.select ~policy:(policy ()) ~term:(Some "demo")
      ~locate:(fun ~term:_ -> Some "/some/path")
      ~read:(fun _ -> Ok (Bytes.of_string "not a compiled terminfo entry"))
  in
  Format.printf "%a@." pp_selection selection;
  [%expect {| fallback=true child_term=xterm-256color identity=xterm-256color |}]

let%expect_test "a parsed resource with a conflicting capability falls back" =
  let selection =
    Selection.select ~policy:(policy ()) ~term:(Some "demo")
      ~locate:(fun ~term:_ -> Some "/some/path")
      ~read:(fun _ -> Ok (incompatible_compiled_terminfo ()))
  in
  Format.printf "%a@." pp_selection selection;
  [%expect {| fallback=true child_term=xterm-256color identity=xterm-256color |}]

let%expect_test "a parsed resource consistent with the bundled family is used as-is, not the fallback" =
  let selection =
    Selection.select ~policy:(policy ()) ~term:(Some "demo")
      ~locate:(fun ~term:_ -> Some "/some/path")
      ~read:(fun _ -> Ok (bundled_compatible_compiled_terminfo ()))
  in
  Format.printf "%a@." pp_selection selection;
  [%expect {| fallback=false child_term=demo identity=demo |}]

let%expect_test "env_with_term replaces an existing TERM entry in place" =
  let env = Selection.env_with_term [| "PATH=/bin"; "TERM=vt100"; "HOME=/home/x" |] ~child_term:"xterm-256color" in
  Format.printf "%a@."
    (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Format.pp_print_string)
    (Array.to_list env);
  [%expect {| PATH=/bin; TERM=xterm-256color; HOME=/home/x |}]

let%expect_test "env_with_term appends TERM when the base environment has none" =
  let env = Selection.env_with_term [| "PATH=/bin" |] ~child_term:"xterm-256color" in
  Format.printf "%a@."
    (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Format.pp_print_string)
    (Array.to_list env);
  [%expect {| PATH=/bin; TERM=xterm-256color |}]

let pp_dirs = Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Format.pp_print_string

let%expect_test "terminfo_dirs_of_env returns no directories when $TERMINFO_DIRS is unset" =
  Format.printf "%a@." pp_dirs (Selection.terminfo_dirs_of_env None);
  [%expect {| |}]

(* lwt-review.md P2: ncurses treats an empty $TERMINFO_DIRS element as "/etc/terminfo at exactly this position",
   not as nothing -- dropping it instead reorders the search and can select the wrong terminal description. *)
let%expect_test "terminfo_dirs_of_env translates a middle empty field to /etc/terminfo, preserving order" =
  Format.printf "%a@." pp_dirs (Selection.terminfo_dirs_of_env (Some "/custom::/other"));
  [%expect {| /custom; /etc/terminfo; /other |}]

let%expect_test "terminfo_dirs_of_env translates a leading empty field to /etc/terminfo" =
  Format.printf "%a@." pp_dirs (Selection.terminfo_dirs_of_env (Some ":/custom"));
  [%expect {| /etc/terminfo; /custom |}]

let%expect_test "terminfo_dirs_of_env translates a trailing empty field to /etc/terminfo" =
  Format.printf "%a@." pp_dirs (Selection.terminfo_dirs_of_env (Some "/custom:"));
  [%expect {| /custom; /etc/terminfo |}]

let%expect_test "terminfo_dirs_of_env translates an entirely empty value to a single /etc/terminfo" =
  Format.printf "%a@." pp_dirs (Selection.terminfo_dirs_of_env (Some ""));
  [%expect {| /etc/terminfo |}]
