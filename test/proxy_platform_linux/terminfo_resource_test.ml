(* terminal-idea.md "asks its platform adapter to locate the corresponding terminfo resource": exercised against a
   temporary directory tree standing in for the real terminfo search path, mirroring how fake_platform.ml stands in
   for a real PTY elsewhere in this project -- no dependency on what happens to be installed on the machine running
   this test. *)
module Resource = Tessera_proxy_platform.Terminfo_resource

let temp_dir () =
  let path = Filename.temp_file "tessera-terminfo-resource-test" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun child -> remove_tree (Filename.concat path child)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let write_entry dir term contents =
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o700;
  let sub = Filename.concat dir (String.make 1 term.[0]) in
  if not (Sys.file_exists sub) then Unix.mkdir sub 0o700;
  let path = Filename.concat sub term in
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel;
  path

let with_root f =
  let root = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let%expect_test "an entry present only in $TERMINFO is found there first" =
  with_root (fun terminfo_root ->
      let expected = write_entry terminfo_root "demo-term" "demo-bytes" in
      let found = Resource.locate ~term:"demo-term" ~home:None ~terminfo:(Some terminfo_root) ~terminfo_dirs:[] in
      Format.printf "%b@." (found = Some expected));
  [%expect {| true |}]

let%expect_test "$TERMINFO takes priority over $HOME/.terminfo" =
  with_root (fun terminfo_root ->
      with_root (fun home ->
          let winner = write_entry terminfo_root "demo-term" "winner" in
          let (_ : string) = write_entry (Filename.concat home ".terminfo") "demo-term" "loser" in
          let found =
            Resource.locate ~term:"demo-term" ~home:(Some home) ~terminfo:(Some terminfo_root) ~terminfo_dirs:[]
          in
          Format.printf "%b@." (found = Some winner)));
  [%expect {| true |}]

let%expect_test "$HOME/.terminfo takes priority over $TERMINFO_DIRS" =
  with_root (fun home ->
      with_root (fun extra_dir ->
          let winner = write_entry (Filename.concat home ".terminfo") "demo-term" "winner" in
          let (_ : string) = write_entry extra_dir "demo-term" "loser" in
          let found = Resource.locate ~term:"demo-term" ~home:(Some home) ~terminfo:None ~terminfo_dirs:[ extra_dir ] in
          Format.printf "%b@." (found = Some winner)));
  [%expect {| true |}]

let%expect_test "$TERMINFO_DIRS entries are searched in order" =
  with_root (fun first_dir ->
      with_root (fun second_dir ->
          let (_ : string) = write_entry second_dir "demo-term" "second" in
          let winner = write_entry first_dir "demo-term" "first" in
          let found =
            Resource.locate ~term:"demo-term" ~home:None ~terminfo:None ~terminfo_dirs:[ first_dir; second_dir ]
          in
          Format.printf "%b@." (found = Some winner)));
  [%expect {| true |}]

let%expect_test "an entry absent from every search path is not found" =
  with_root (fun terminfo_root ->
      let found = Resource.locate ~term:"nowhere" ~home:None ~terminfo:(Some terminfo_root) ~terminfo_dirs:[] in
      Format.printf "%b@." (found = None));
  [%expect {| true |}]

let%expect_test "read returns the exact bytes of a located file" =
  with_root (fun terminfo_root ->
      let path = write_entry terminfo_root "demo-term" "\000\001\002binary-ish" in
      match Resource.read path with
      | Ok bytes -> Format.printf "%d %s@." (Bytes.length bytes) (String.escaped (Bytes.to_string bytes))
      | Error error -> Format.printf "error: %a@." Resource.pp_error error);
  [%expect {| 13 \000\001\002binary-ish |}]

let%expect_test "read reports a typed error for a missing file" =
  with_root (fun terminfo_root ->
      match Resource.read (Filename.concat terminfo_root "missing") with
      | Ok _ -> print_endline "unexpectedly ok"
      | Error (`Read_failed _) -> print_endline "read-failed");
  [%expect {| read-failed |}]

(* lwt-review.md P2: [terminfo]/[home]/[terminfo_dirs] are all env-var-controlled, so a candidate path can name a
   sparse regular file whose apparent [fstat] size is far larger than the disk space it actually occupies. This must
   be rejected as a typed [Read_failed] before the corresponding allocation is attempted, not merely "eventually" --
   a real oversized allocation here is exactly the failure mode this test rules out. *)
let%expect_test "read rejects a sparse file whose apparent length exceeds the resource size cap" =
  with_root (fun terminfo_root ->
      let path = Filename.concat terminfo_root "huge" in
      let channel = open_out_bin path in
      close_out channel;
      Unix.LargeFile.truncate path (Int64.of_int (Resource.max_bytes + 1));
      match Resource.read path with
      | Ok _ -> print_endline "unexpectedly ok"
      | Error (`Read_failed _) -> print_endline "read-failed");
  [%expect {| read-failed |}]

let%expect_test "read still accepts a file exactly at the resource size cap" =
  with_root (fun terminfo_root ->
      let path = Filename.concat terminfo_root "at-cap" in
      let channel = open_out_bin path in
      close_out channel;
      Unix.LargeFile.truncate path (Int64.of_int Resource.max_bytes);
      match Resource.read path with
      | Ok bytes -> Format.printf "%b@." (Bytes.length bytes = Resource.max_bytes)
      | Error error -> Format.printf "unexpected error: %a@." Resource.pp_error error);
  [%expect {| true |}]
