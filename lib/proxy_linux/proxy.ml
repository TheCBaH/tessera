(* The composition root / eventual tessera-proxy executable (proxy.md section 5, implementation order
   step 5): spawns a child under a real PTY, relays both directions, drives the resize protocol, and
   feeds the observer ring. The observer ring is additionally exposed over a private local Unix-domain
   socket (milestones.md "observable proxy service"; see Tessera_proxy_linux.Observer_server for the
   wire protocol/authentication model) -- a later, separate increment from proxy.md's original scope,
   which stopped at the in-process ring. *)

module Platform = Tessera_proxy_platform_linux.Platform_linux
module Session = Tessera_proxy_linux.Session.Make (Platform)
module Observer_server = Tessera_proxy_linux.Observer_server

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

(* [XDG_RUNTIME_DIR] is already mode [0o700] and per-user by convention on a system that sets it;
   falling back to [/tmp] still gets the same protection from {!Observer_server.create}'s own private,
   [0o700] subdirectory. Each proxy process gets its own socket, named by pid, so unrelated concurrent
   proxy runs never collide. *)
let default_socket_path () =
  let base = match Sys.getenv_opt "XDG_RUNTIME_DIR" with Some dir -> dir | None -> "/tmp" in
  Filename.concat (Filename.concat base "tessera-proxy") (Printf.sprintf "%d.sock" (Unix.getpid ()))

let create_observer_server ~ring ~policy =
  match Observer_server.create ~socket_path:(default_socket_path ()) ~ring ~policy ~max_pending_bytes:1_048_576 with
  | Ok server -> Some server
  | Error error ->
      Printf.eprintf "tessera-proxy: observer socket disabled: %s\n%!"
        (Format.asprintf "%a" Observer_server.pp_error (Err.Error.kind error));
      None

let run_loop session observer =
  let rec loop () =
    let extra_read_fds, extra_write_fds =
      match observer with
      | None -> ([], [])
      | Some server ->
          (Observer_server.listen_fd server :: Observer_server.read_fds server, Observer_server.write_fds server)
    in
    match Session.select session ~extra_read_fds ~extra_write_fds ~timeout:(-1.0) with
    | [] -> loop ()
    | ready ->
        let continue_ = ref true in
        List.iter
          (fun ready ->
            if !continue_ then
              match ready with
              | Session.Wakeup -> (
                  match Session.on_wakeup session with
                  | Session.Resized (Session.Loop.Resized outcome) ->
                      Option.iter (fun server -> Observer_server.note_outcome server outcome) observer
                  | Session.Resized (Session.Loop.Reported _) -> ()
                  | _ -> ())
              | Session.Master -> (
                  match Session.on_master_readable session with
                  | Session.Application_eof outcome ->
                      Option.iter (fun server -> Observer_server.note_outcome server outcome) observer;
                      continue_ := false
                  | Session.Application_bytes outcome ->
                      Option.iter (fun server -> Observer_server.note_outcome server outcome) observer
                  | Session.Application_ingest_failed _ -> Option.iter Observer_server.drain observer
                  | _ -> ())
              | Session.Terminal_input -> (
                  match Session.on_terminal_readable session with
                  | Session.Terminal_input_eof -> continue_ := false
                  | Session.Terminal_input_relayed _ -> Option.iter Observer_server.drain observer
                  | _ -> ())
              | Session.Extra_read fd -> (
                  match observer with
                  | None -> ()
                  | Some server ->
                      if fd = Observer_server.listen_fd server then Observer_server.accept server
                      else Observer_server.on_readable server fd)
              | Session.Extra_write fd -> Option.iter (fun server -> Observer_server.on_writable server fd) observer)
          ready;
        if !continue_ then loop ()
  in
  loop ()

(* terminal-idea.md "Terminal descriptions and terminfo": discover and parse the host's own declared terminal type,
   or fall back to the bundled xterm-256color definition and advertise that fallback to the PTY-side application by
   overriding its TERM. That advertisement is deliberately the only observable side effect: this process's own
   stdout/stderr are the real terminal the child's output is about to be relayed onto verbatim, so nothing here
   prints a startup diagnostic there -- a message on that shared terminal would be indistinguishable from the child's
   own output and would corrupt the very transparency this proxy exists to preserve. *)
let select_terminal ~policy =
  let terminfo_dirs =
    match Sys.getenv_opt "TERMINFO_DIRS" with
    | None -> []
    | Some value -> String.split_on_char ':' value |> List.filter (fun dir -> dir <> "")
  in
  Tessera_proxy_linux.Terminal_selection.select ~policy ~term:(Sys.getenv_opt "TERM")
    ~locate:(fun ~term ->
      Tessera_proxy_platform.Terminfo_resource.locate ~term ~home:(Sys.getenv_opt "HOME")
        ~terminfo:(Sys.getenv_opt "TERMINFO") ~terminfo_dirs)
    ~read:Tessera_proxy_platform.Terminfo_resource.read

let () =
  let argv =
    if Array.length Sys.argv > 1 then Array.sub Sys.argv 1 (Array.length Sys.argv - 1)
    else match Sys.getenv_opt "SHELL" with Some shell -> [| shell |] | None -> [| "/bin/sh" |]
  in
  let policy = default_policy () in
  let selection = select_terminal ~policy in
  let env =
    Tessera_proxy_linux.Terminal_selection.env_with_term (Unix.environment ()) ~child_term:selection.child_term
  in
  let lineage_id =
    Tessera_foundation.Lineage_id.of_uint
      (match Tessera_foundation.UInt.of_int 1 with Ok v -> v | Error _ -> assert false)
  in
  let original_termios = enter_raw_mode Unix.stdin in
  Fun.protect
    ~finally:(fun () -> leave_raw_mode Unix.stdin original_termios)
    (fun () ->
      match
        Session.create ~argv ~env ~lineage_id ~policy ~terminal_in:Unix.stdin ~terminal_out:Unix.stdout
          ~observer_capacity:4096 ~observer_start_position:Tessera_proxy_observer.Record.initial_sequence
          ~read_buffer_bytes:65536
      with
      | Error error -> die (Format.asprintf "%a" Session.Loop.pp_error error)
      | Ok session ->
          let observer = create_observer_server ~ring:(Session.ring session) ~policy in
          Fun.protect
            ~finally:(fun () -> Option.iter Observer_server.close observer)
            (fun () -> run_loop session observer))
