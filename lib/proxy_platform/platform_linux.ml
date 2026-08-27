module Foundation = Tessera_foundation
module Winsize = Tessera_proxy_platform.Winsize

type pty = { master : Unix.file_descr }
type error = Unix_error of Unix.error * string * string | Empty_argv | No_controlling_terminal

let pp_error ppf = function
  | Unix_error (code, fn, arg) -> Format.fprintf ppf "unix-error(%s(%s): %s)" fn arg (Unix.error_message code)
  | Empty_argv -> Format.pp_print_string ppf "empty-argv"
  | No_controlling_terminal -> Format.pp_print_string ppf "no-controlling-terminal"

let wrap_unix_error f = try Ok (f ()) with Unix.Unix_error (code, fn, arg) -> Error (Unix_error (code, fn, arg))

external raw_openpty : int -> int -> int -> int -> Unix.file_descr * Unix.file_descr = "tessera_openpty_stub"
external raw_setsid_set_ctty : Unix.file_descr -> unit = "tessera_setsid_set_ctty_stub"
external raw_get_winsize : Unix.file_descr -> int * int * int * int = "tessera_get_winsize_stub"
external raw_set_winsize : Unix.file_descr -> int -> int -> int -> int -> unit = "tessera_set_winsize_stub"
external raw_notify_winch : Unix.file_descr -> unit = "tessera_notify_winch_stub"
external raw_block_sigwinch_signalfd : unit -> Unix.file_descr = "tessera_block_sigwinch_signalfd_stub"
external raw_reset_child_signals : unit -> unit = "tessera_reset_child_signals_stub"

(* Blocks SIGWINCH and creates its signalfd exactly once per process, the first time it is forced.
   Forced at the very top of [spawn], before the PTY is even opened, so the block is in effect before
   fork() -- see platform_stubs.c's comment on tessera_block_sigwinch_signalfd_stub for why this
   ordering, and the single-thread requirement, matter. *)
let winch_signalfd = lazy (raw_block_sigwinch_signalfd ())
let must_uint n = match Foundation.UInt.of_int n with Ok value -> value | Error _ -> assert false

let winsize_of_raw (rows, columns, xpixel, ypixel) =
  let pixels =
    if xpixel = 0 && ypixel = 0 then None else Some { Winsize.width = xpixel; height = ypixel; unit = Device_pixels }
  in
  Winsize.make ~columns:(must_uint columns) ~rows:(must_uint rows) ~pixels

(* The C stubs store every field in a [struct winsize]'s [unsigned short], so a value outside
   [0, 0xFFFF] would otherwise be truncated silently (e.g. an out-of-range column count wrapping
   to a small, wrong one) instead of failing -- exactly the kind of silent geometry corruption
   terminal-plan.md's resize protocol is designed to avoid. [Foundation.UInt.t] has no upper bound
   of its own, so this is the boundary that must enforce one. *)
let winsize_field_max = 0xFFFF

let check_winsize_field name value =
  if value < 0 || value > winsize_field_max then
    raise
      (Unix.Unix_error
         ( Unix.EINVAL,
           "winsize",
           Printf.sprintf "%s=%d exceeds unsigned 16-bit range [0, %d]" name value winsize_field_max ))

let raw_of_winsize winsize =
  let rows = Foundation.UInt.to_int (Winsize.rows winsize) in
  let columns = Foundation.UInt.to_int (Winsize.columns winsize) in
  let xpixel, ypixel =
    match Winsize.pixels winsize with Some { Winsize.width; height; _ } -> (width, height) | None -> (0, 0)
  in
  check_winsize_field "rows" rows;
  check_winsize_field "columns" columns;
  check_winsize_field "xpixel" xpixel;
  check_winsize_field "ypixel" ypixel;
  (rows, columns, xpixel, ypixel)

let spawn ~argv ~initial_winsize =
  if Array.length argv = 0 then Error Empty_argv
  else
    let (_ : Unix.file_descr) = Lazy.force winch_signalfd in
    wrap_unix_error (fun () ->
        let rows, columns, xpixel, ypixel = raw_of_winsize initial_winsize in
        let master, slave = raw_openpty rows columns xpixel ypixel in
        match Unix.fork () with
        | 0 -> (
            try
              Unix.close master;
              raw_setsid_set_ctty slave;
              raw_reset_child_signals ();
              Unix.dup2 slave Unix.stdin;
              Unix.dup2 slave Unix.stdout;
              Unix.dup2 slave Unix.stderr;
              if slave <> Unix.stdin && slave <> Unix.stdout && slave <> Unix.stderr then Unix.close slave;
              Unix.execvp argv.(0) argv
              (* _exit, not Stdlib.exit, deliberately: skips at_exit handlers and buffered-channel
                 flushes that would otherwise run again (once per process) after this fork, mirroring
                 Unix.create_process's own child-side error handling. *)
            with _ -> Unix._exit 127)
        | _child_pid ->
            Unix.close slave;
            { master })

let master_fd pty = pty.master
let get_winsize pty = wrap_unix_error (fun () -> winsize_of_raw (raw_get_winsize pty.master))

let set_winsize pty winsize =
  wrap_unix_error (fun () ->
      let rows, columns, xpixel, ypixel = raw_of_winsize winsize in
      raw_set_winsize pty.master rows columns xpixel ypixel)

let notify_unchanged_winsize pty = wrap_unix_error (fun () -> raw_notify_winch pty.master)
let resize_wakeup_fd (_ : pty) = Lazy.force winch_signalfd

let physical_winsize () =
  let rec try_candidates = function
    | [] -> Error No_controlling_terminal
    | fd :: rest -> (
        match wrap_unix_error (fun () -> winsize_of_raw (raw_get_winsize fd)) with
        | Ok _ as ok -> ok
        | Error _ -> try_candidates rest)
  in
  try_candidates [ Unix.stdin; Unix.stdout; Unix.stderr ]
