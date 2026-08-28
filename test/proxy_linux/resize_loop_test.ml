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
  let outcome = Lwt_main.run (Loop.requery loop) in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    resized(size=6×3)
    calls: [set-winsize(6×3)] |}]

let%expect_test "a same-size notification calls notify_unchanged_winsize and not a redundant set_winsize" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  Fake_platform.set_physical_winsize (or_fail (winsize 4 2));
  let outcome = Lwt_main.run (Loop.requery loop) in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    resized(size=4×2)
    calls: [notify-unchanged] |}]

let%expect_test "a zero/invalid queried size applies the raw value best-effort but never calls Lwt_adapter.resize" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let raw = Winsize.make ~columns:(or_fail (uint 0)) ~rows:(or_fail (uint 3)) ~pixels:None in
  Fake_platform.set_physical_winsize raw;
  let outcome = Lwt_main.run (Loop.requery loop) in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    reported(unmodelled-resize(0×3))
    calls: [set-winsize(0×3)] |}]

let%expect_test "a failed physical query is reported and never fabricated into a core update" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  Fake_platform.fail_physical_winsize (Fake_platform.Simulated "ioctl failed");
  let outcome = Lwt_main.run (Loop.requery loop) in
  Format.printf "%a@." pp_outcome outcome;
  print_calls loop;
  [%expect {|
    reported(physical-query-failed(simulated(ioctl failed)))
    calls: [] |}]

(* [Loop.select]'s fd-classifying combinator (and with it, this layer's old "wakeup is ordered first" ordering test)
   is gone: [Loop] now only exposes {!Loop.wait_for_wakeup}, a single-fd wait a caller loops itself. Ordering against
   the master/terminal descriptors is no longer this layer's concern at all -- see session_test.ml, where
   {!Session.run_resize_loop} and {!Session.run_master_loop} run as independent Lwt tasks with no ordering contract
   between them. *)
let%expect_test "wait_for_wakeup resolves once a host resize notification has arrived" =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let pty = Loop.pty loop in
  let resolved = ref false in
  let waiter = Lwt.map (fun () -> resolved := true) (Loop.wait_for_wakeup loop) in
  Format.printf "resolved before the notification: %b@." !resolved;
  Fake_platform.trigger_host_resize pty;
  Lwt_main.run waiter;
  Format.printf "resolved after the notification: %b@." !resolved;
  [%expect {|
    resolved before the notification: false
    resolved after the notification: true |}]

let%expect_test "each lifecycle re-query point drives the identical physical_winsize/set_winsize path as a live wake-up"
    =
  let loop = start ~initial_columns:4 ~initial_rows:2 in
  let pty = Loop.pty loop in
  Fake_platform.reset_physical_winsize_calls ();
  (* A live wake-up: drains the pipe, then queries and applies exactly like a lifecycle re-query. *)
  Fake_platform.set_physical_winsize (or_fail (winsize 6 2));
  Fake_platform.trigger_host_resize pty;
  let wakeup_outcome = Lwt_main.run (Lwt.bind (Loop.wait_for_wakeup loop) (fun () -> Loop.on_wakeup loop)) in
  Fake_platform.reset_calls pty;
  (* A lifecycle re-query point (e.g. resume/reattach/pre-resume): identical steps, no signal fired. *)
  Fake_platform.set_physical_winsize (or_fail (winsize 8 3));
  let requery_outcome = Lwt_main.run (Loop.requery loop) in
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
