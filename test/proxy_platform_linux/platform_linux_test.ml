(* Layer 4 (proxy.md "Testing"): real integration against the real Tessera_proxy_platform_linux
   binding and a real spawned child. Since this test runner has no real controlling terminal of its
   own, it gives itself one: a second, throwaway real PTY (spawned the same way as the child under
   test) whose master it dup2's onto its own fd 0, so Platform_linux.physical_winsize() -- which reads
   fd 0/1/2 -- has something real to observe and the test can drive it directly, per proxy.md's own
   note that this harness "is not run inside a real terminal". *)

module Foundation = Tessera_foundation
module Platform_linux = Tessera_proxy_platform_linux.Platform_linux
module Winsize = Tessera_proxy_platform.Winsize
module Loop = Tessera_proxy_linux.Resize_loop.Make (Platform_linux)

(* Linux's SIGWINCH signal number; not exposed by Stdlib.Sys. *)
let sigwinch = 28
let failures = ref 0

let check label condition =
  if condition then Printf.printf "PASS %s\n%!" label
  else (
    incr failures;
    Printf.printf "FAIL %s\n%!" label)

let or_fail_platform = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Platform_linux.pp_error error)

let uint n = match Foundation.UInt.of_int n with Ok value -> value | Error _ -> failwith "uint"
let winsize columns rows = Winsize.make ~columns:(uint columns) ~rows:(uint rows) ~pixels:None

let read_byte fd ~timeout =
  match Unix.select [ fd ] [] [] timeout with
  | [], _, _ -> None
  | _ -> (
      let buffer = Bytes.create 1 in
      match Unix.read fd buffer 0 1 with
      | 1 -> Some (Bytes.get buffer 0)
      | _ -> None
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> None)

let read_line fd ~timeout =
  let buffer = Buffer.create 64 in
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0.0 then None
    else
      match read_byte fd ~timeout:remaining with
      | None -> None
      | Some '\n' -> Some (Buffer.contents buffer)
      | Some '\r' -> loop ()
      | Some c ->
          Buffer.add_char buffer c;
          loop ()
  in
  loop ()

let write_all fd text =
  let bytes = Bytes.of_string text in
  let len = Bytes.length bytes in
  let written = ref 0 in
  while !written < len do
    written := !written + Unix.write fd bytes !written (len - !written)
  done

let read_exact fd count ~timeout =
  let buffer = Bytes.create count in
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop offset =
    if offset >= count then Some (Bytes.to_string buffer)
    else
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then None
      else
        match Unix.select [ fd ] [] [] remaining with
        | [], _, _ -> None
        | _ -> (
            match Unix.read fd buffer offset (count - offset) with
            | 0 -> None
            | read -> loop (offset + read)
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset)
  in
  loop 0

let expect_winsize_line fd ~expected ~label =
  match read_line fd ~timeout:5.0 with
  | Some line -> check label (line = Format.asprintf "winsize %a" Winsize.pp expected)
  | None -> check (label ^ " (no line received)") false

let expect_resized loop ~expected ~label =
  match Loop.on_wakeup loop with
  | Loop.Resized outcome -> (
      match Tessera.Patch.size (Tessera.outcome_patch outcome) with
      | Tessera.Patch.Set size ->
          check label
            (Foundation.UInt.equal (Winsize.columns expected) (Foundation.Types.Size.columns size)
            && Foundation.UInt.equal (Winsize.rows expected) (Foundation.Types.Size.rows size))
      | Tessera.Patch.Keep -> check (label ^ " (patch reported Keep, not Set)") false)
  | Loop.Reported diagnostic ->
      check (Format.asprintf "%s (reported %a instead of Resized)" label Loop.pp_diagnostic diagnostic) false

let () =
  if Array.length Sys.argv < 2 then failwith "expected the winsize_probe executable path as argv.(1)";
  let helper_path = Sys.argv.(1) in
  let size_a = winsize 20 6 in
  let size_b = winsize 30 10 in

  let host = or_fail_platform (Platform_linux.spawn ~argv:[| "/bin/cat" |] ~initial_winsize:size_a) in
  Unix.dup2 (Platform_linux.master_fd host) Unix.stdin;

  let policy =
    match Tessera_test_support.Support.policy () with Ok policy -> policy | Error message -> failwith message
  in
  let lineage_id = Foundation.Lineage_id.of_uint (uint 1) in
  let loop =
    match Loop.startup ~argv:[| helper_path |] ~lineage_id ~policy with
    | Ok loop -> loop
    | Error error -> failwith (Format.asprintf "startup failed: %a" Loop.pp_error error)
  in
  let child_master = Platform_linux.master_fd (Loop.pty loop) in

  expect_winsize_line child_master ~expected:size_a
    ~label:"the child observes the exact winsize spawn applied at startup";

  (* Simulate a host resize: change what physical_winsize() will read (a real ioctl on a real pty),
     then drive resize_wakeup_fd with a real kernel SIGWINCH to our own process -- proxy.md's "directly
     invoking whatever drives physical_winsize/resize_wakeup_fd in the test harness". *)
  or_fail_platform (Result.map ignore (Platform_linux.set_winsize host size_b));
  Unix.kill (Unix.getpid ()) sigwinch;
  let ready = Loop.select loop ~other_read_fds:[] ~write_fds:[] ~timeout:5.0 in
  check "resize_wakeup_fd becomes ready after a real SIGWINCH to this process" (List.mem Loop.Wakeup ready);
  expect_resized loop ~expected:size_b
    ~label:"a distinct-size requery calls Unix_adapter.resize with the expected geometry";
  expect_winsize_line child_master ~expected:size_b
    ~label:"the child observes a real SIGWINCH after set_winsize (distinct size)";

  (* Host stays at size_b: the next requery must take the same-size/notify_unchanged_winsize path,
     which still delivers a real SIGWINCH to the child directly (TIOCSWINSZ alone would not). *)
  Unix.kill (Unix.getpid ()) sigwinch;
  expect_resized loop ~expected:size_b
    ~label:"a same-size requery also calls Unix_adapter.resize (full-projection refresh)";
  expect_winsize_line child_master ~expected:size_b
    ~label:"the child observes a real SIGWINCH from notify_unchanged_winsize (same size)";

  let payload = "the quick brown fox 0123456789" in
  write_all child_master payload;
  (match read_exact child_master (String.length payload) ~timeout:5.0 with
  | Some echoed -> check "byte-for-byte relay round-trip over the real PTY pair" (String.equal echoed payload)
  | None -> check "byte-for-byte relay round-trip over the real PTY pair (no echo received)" false);

  (* A column count that would not fit in the C stubs' unsigned-short winsize fields must be rejected
     as a typed error, not silently truncated into a different, wrong geometry
     (Tessera_proxy_platform_linux.Platform_linux.check_winsize_field). *)
  let oversized = winsize 100_000 24 in
  (match Platform_linux.set_winsize host oversized with
  | Error _ -> check "set_winsize rejects a column count that would overflow struct winsize's unsigned short" true
  | Ok () -> check "set_winsize rejects a column count that would overflow struct winsize's unsigned short" false);
  (match Platform_linux.get_winsize host with
  | Ok observed ->
      check "a rejected oversized set_winsize leaves the previously applied geometry untouched"
        (Foundation.UInt.equal (Winsize.columns observed) (Winsize.columns size_b)
        && Foundation.UInt.equal (Winsize.rows observed) (Winsize.rows size_b))
  | Error error -> check (Format.asprintf "get_winsize after rejected resize (%a)" Platform_linux.pp_error error) false);

  if !failures > 0 then (
    Printf.printf "%d check(s) failed\n%!" !failures;
    exit 1)
  else print_endline "all layer-4 checks passed"
