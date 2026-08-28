(* Layer 1 (proxy.md "Testing"): the resize protocol's rules, exercised against Fake_platform. No
   real signal, no real PTY, no timing dependency. *)
module Foundation = Tessera_foundation
module Platform = Tessera_proxy_platform
module Winsize = Platform.Winsize
open Tessera_test_support.Support
module Fake_platform = Tessera_test_proxy_linux_fake_platform.Fake_platform
module Loop = Tessera_proxy_linux.Resize_loop.Make (Fake_platform)

let ( let* ) = Result.bind

let winsize columns rows =
  let* columns = uint columns and* rows = uint rows in
  Ok (Winsize.make ~columns ~rows ~pixels:None)

let or_fail = function Ok value -> value | Error message -> failwith message

let pp_outcome ppf = function
  | Loop.Resized outcome ->
      let patch = Tessera.outcome_patch outcome in
      let size =
        match Tessera.Patch.size patch with
        | Tessera.Patch.Keep -> "keep"
        | Tessera.Patch.Set size -> Format.asprintf "%a" Foundation.Types.Size.pp size
      in
      Format.fprintf ppf "resized(size=%s)" size
  | Loop.Reported diagnostic -> Format.fprintf ppf "reported(%a)" Loop.pp_diagnostic diagnostic

let start ~initial_columns ~initial_rows =
  Fake_platform.set_physical_winsize (or_fail (winsize initial_columns initial_rows));
  let lineage_id = Foundation.Lineage_id.of_uint (or_fail (uint 1)) in
  let policy = or_fail (policy ()) in
  match Loop.startup ~argv:[| "/bin/true" |] ~env:[||] ~lineage_id ~policy with
  | Ok loop -> loop
  | Error error -> failwith (Format.asprintf "%a" Loop.pp_error error)

let print_calls loop =
  Format.printf "calls: [%a]@."
    (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") Fake_platform.pp_call)
    (Fake_platform.calls (Loop.pty loop))

let%expect_test "a distinct-size notification calls set_winsize and not notify_unchanged_winsize" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  Fake_platform.set_physical_winsize (or_fail (winsize 6 3));
  let outcome = Loop.requery loop in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    resized(size=6×3)
    calls: [set-winsize(6×3)] |}]

let%expect_test "a same-size notification calls notify_unchanged_winsize and not a redundant set_winsize" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  Fake_platform.set_physical_winsize (or_fail (winsize 4 2));
  let outcome = Loop.requery loop in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    resized(size=4×2)
    calls: [notify-unchanged] |}]

let%expect_test "a zero/invalid queried size applies the raw value best-effort but never calls Unix_adapter.resize" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let raw = Winsize.make ~columns:(or_fail (uint 0)) ~rows:(or_fail (uint 3)) ~pixels:None in
  Fake_platform.set_physical_winsize raw;
  let outcome = Loop.requery loop in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    reported(unmodelled-resize(0×3))
    calls: [set-winsize(0×3)] |}]

let%expect_test "a failed physical query is reported and never fabricated into a core update" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  Fake_platform.fail_physical_winsize (Fake_platform.Simulated "ioctl failed");
  let outcome = Loop.requery loop in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    reported(physical-query-failed(simulated(ioctl failed)))
    calls: [] |}]

let%expect_test "when both the wake-up and child-output descriptors are ready, the resize is ordered first" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let pty = Loop.pty loop in
  let master = Fake_platform.master_fd pty in
  Fake_platform.trigger_host_resize pty;
  Fake_platform.push_child_output pty "hello";
  let ready = Loop.select loop ~other_read_fds:[ master ] ~write_fds:[] ~timeout:1.0 in
  let pp_ready ppf = function
    | Loop.Wakeup -> Format.pp_print_string ppf "wakeup"
    | Loop.Fd _ -> Format.pp_print_string ppf "master"
    | Loop.Writable _ -> Format.pp_print_string ppf "writable"
  in
  Format.printf "[%a]@." (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ") pp_ready) ready;
  [%expect {| [wakeup; master] |}]

let%expect_test "with only the child-output descriptor ready, select reports only that descriptor" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let pty = Loop.pty loop in
  let master = Fake_platform.master_fd pty in
  Fake_platform.push_child_output pty "hello";
  let ready = Loop.select loop ~other_read_fds:[ master ] ~write_fds:[] ~timeout:1.0 in
  Format.printf "%d ready@." (List.length ready);
  [%expect {| 1 ready |}]

let%expect_test "each lifecycle re-query point drives the identical physical_winsize/set_winsize path as a live wake-up"
    =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let pty = Loop.pty loop in
  Fake_platform.reset_physical_winsize_calls ();
  (* A live wake-up: drains the pipe, then queries and applies exactly like a lifecycle re-query. *)
  Fake_platform.set_physical_winsize (or_fail (winsize 6 2));
  Fake_platform.trigger_host_resize pty;
  let wakeup_outcome = Loop.on_wakeup loop in
  Fake_platform.reset_calls pty;
  (* A lifecycle re-query point (e.g. resume/reattach/pre-resume): identical steps, no signal fired. *)
  Fake_platform.set_physical_winsize (or_fail (winsize 8 3));
  let requery_outcome = Loop.requery loop in
  Format.printf "wake-up: %a@." pp_outcome wakeup_outcome;
  Format.printf "re-query: %a@." pp_outcome requery_outcome;
  Format.printf "physical_winsize calls: %d@." (Fake_platform.physical_winsize_call_count ());
  print_calls loop;
  [%expect
    {|
    wake-up: resized(size=6×2)
    re-query: resized(size=8×3)
    physical_winsize calls: 2
    calls: [set-winsize(8×3)] |}]
