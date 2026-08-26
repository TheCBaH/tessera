(* The composition root / eventual tessera-proxy executable (proxy.md section 5, implementation order
   step 5): spawns a child under a real PTY, relays both directions, drives the resize protocol, and
   feeds the observer ring. No wire protocol or socket server yet -- a later, separate increment. *)

module Platform = Tessera_proxy_platform_linux.Platform_linux
module Session = Tessera_proxy_linux.Session.Make (Platform)

let die message =
  Printf.eprintf "tessera-proxy: %s\n%!" message;
  exit 1

(* A generous, fixed policy: this executable has no configuration surface yet, only the minimal relay
   the acceptance gate requires. max_columns/max_rows bound how large the core will ever allow the
   *current* geometry to grow, independent of the actual size the resize protocol applies. *)
let default_policy () =
  let uint n =
    match Tessera_foundation.UInt.of_int n with
    | Ok value -> value
    | Error error ->
        die
          (Format.asprintf "invalid built-in policy limit %d: %a" n
             (Err.Error.pp_kind Tessera_foundation.UInt.pp_error)
             error)
  in
  match
    Tessera_foundation.Limits.make ~max_columns:(uint 1000) ~max_control_bytes:(uint 65536) ~max_csi_params:(uint 64)
      ~max_diagnostics:(uint 256) ~max_rows:(uint 1000) ~max_slice_bytes:(uint 65536)
      ~max_snapshot_cells:(uint 1_000_000)
  with
  | Error error ->
      die (Format.asprintf "invalid built-in policy: %a" (Err.Error.pp_kind Tessera_foundation.Limits.pp_error) error)
  | Ok limits -> Tessera_foundation.Policy.make ~limits ~profile:Tessera_foundation.Policy.Xterm_256color_core

(* Puts the real terminal into raw mode for the proxy's duration: canonical-mode line editing and
   local echo must be off so the child (not the outer terminal) is the only thing the user's keystrokes
   and the application's output pass through, matching how a real terminal proxy (script, tmux, ...)
   behaves. Left alone (returns [None]) when fd isn't actually a terminal -- e.g. piped input in a
   non-interactive invocation -- since there is then nothing to put in raw mode or restore. *)
let enter_raw_mode fd =
  match Unix.tcgetattr fd with
  | exception Unix.Unix_error _ -> None
  | original ->
      let raw =
        {
          original with
          Unix.c_icanon = false;
          c_echo = false;
          c_isig = false;
          c_ixon = false;
          c_icrnl = false;
          c_opost = false;
          c_vmin = 1;
          c_vtime = 0;
        }
      in
      Unix.tcsetattr fd Unix.TCSANOW raw;
      Some original

let leave_raw_mode fd original =
  match original with
  | None -> ()
  | Some original -> ( try Unix.tcsetattr fd Unix.TCSANOW original with Unix.Unix_error _ -> ())

let run_loop session =
  let rec loop () =
    match Session.select session ~timeout:(-1.0) with
    | [] -> loop ()
    | ready ->
        let continue_ = ref true in
        List.iter
          (fun ready ->
            if !continue_ then
              match ready with
              | Session.Wakeup -> ignore (Session.on_wakeup session)
              | Session.Master -> (
                  match Session.on_master_readable session with
                  | Session.Application_eof _ -> continue_ := false
                  | _ -> ())
              | Session.Terminal_input -> (
                  match Session.on_terminal_readable session with
                  | Session.Terminal_input_eof -> continue_ := false
                  | _ -> ()))
          ready;
        if !continue_ then loop ()
  in
  loop ()

let () =
  let argv =
    if Array.length Sys.argv > 1 then Array.sub Sys.argv 1 (Array.length Sys.argv - 1)
    else match Sys.getenv_opt "SHELL" with Some shell -> [| shell |] | None -> [| "/bin/sh" |]
  in
  let policy = default_policy () in
  let lineage_id =
    Tessera_foundation.Lineage_id.of_uint
      (match Tessera_foundation.UInt.of_int 1 with Ok v -> v | Error _ -> assert false)
  in
  let original_termios = enter_raw_mode Unix.stdin in
  Fun.protect
    ~finally:(fun () -> leave_raw_mode Unix.stdin original_termios)
    (fun () ->
      match
        Session.create ~argv ~lineage_id ~policy ~terminal_in:Unix.stdin ~terminal_out:Unix.stdout
          ~observer_capacity:4096 ~read_buffer_bytes:65536
      with
      | Error error -> die (Format.asprintf "%a" Session.Loop.pp_error error)
      | Ok session -> run_loop session)
