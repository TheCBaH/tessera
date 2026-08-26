(* Fake implementation of Tessera_proxy_platform.Platform.S (proxy.md testing layer 1): a
   thread-free, single Unix.pipe standing in for resize_wakeup_fd (tests write a byte to simulate a
   host SIGWINCH), and mutable refs standing in for the physical and child winsize. No real PTY, no
   real child process, no real signal -- this lets every rule in proxy.md section 2 be a fast native
   ppx_expect test with no timing dependency. *)

module Platform_types = Tessera_proxy_platform
module Winsize = Platform_types.Winsize

type error = Simulated of string

let pp_error ppf (Simulated message) = Format.fprintf ppf "simulated(%s)" message

type call = Set_winsize of Winsize.t | Notify_unchanged

let pp_call ppf = function
  | Set_winsize winsize -> Format.fprintf ppf "set-winsize(%a)" Winsize.pp winsize
  | Notify_unchanged -> Format.pp_print_string ppf "notify-unchanged"

type pty = {
  master_end : Unix.file_descr;  (** returned by {!master_fd} -- reads and writes like a real PTY master. *)
  test_end : Unix.file_descr;  (** the fake's private counterpart: push output on it, read what was sent to it. *)
  wakeup_read : Unix.file_descr;
  wakeup_write : Unix.file_descr;
  mutable applied : Winsize.t;
  mutable calls : call list; (* newest first *)
}

(* physical_winsize has no pty argument in Platform.S -- it is one physical terminal per process, not
   per pty -- so its simulated state is necessarily process-global, matching the real Linux binding. *)
let physical_winsize_ref : (Winsize.t, error) result ref =
  ref (Error (Simulated "physical_winsize not configured by this test"))

let physical_winsize_calls = ref 0
let set_physical_winsize winsize = physical_winsize_ref := Ok winsize
let fail_physical_winsize error = physical_winsize_ref := Error error
let physical_winsize_call_count () = !physical_winsize_calls
let reset_physical_winsize_calls () = physical_winsize_calls := 0

let physical_winsize () =
  incr physical_winsize_calls;
  !physical_winsize_ref

let spawn ~argv:_ ~initial_winsize =
  let master_end, test_end = Unix.socketpair ~cloexec:true PF_UNIX SOCK_STREAM 0 in
  let wakeup_read, wakeup_write = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock wakeup_read;
  Ok { master_end; test_end; wakeup_read; wakeup_write; applied = initial_winsize; calls = [] }

let master_fd pty = pty.master_end
let get_winsize pty = Ok pty.applied

let set_winsize pty winsize =
  pty.applied <- winsize;
  pty.calls <- Set_winsize winsize :: pty.calls;
  Ok ()

let notify_unchanged_winsize pty =
  pty.calls <- Notify_unchanged :: pty.calls;
  Ok ()

let resize_wakeup_fd pty = pty.wakeup_read

(* Test-only controls, not part of Platform.S. *)

let rec write_all fd bytes offset =
  if offset < Bytes.length bytes then
    match Unix.write fd bytes offset (Bytes.length bytes - offset) with
    | written -> write_all fd bytes (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd bytes offset

let push_child_bytes pty bytes = write_all pty.test_end bytes 0
let push_child_output pty text = push_child_bytes pty (Bytes.of_string text)

(* Reads whatever was written to [master_fd pty] (e.g. by a proxy relaying terminal input to the
   child), waiting up to [timeout] seconds. [None] means nothing arrived in time. *)
let rec read_sent_to_child pty ~len =
  Unix.set_nonblock pty.test_end;
  let buffer = Bytes.create len in
  match Unix.read pty.test_end buffer 0 len with
  | 0 -> None
  | read -> Some (Bytes.sub_string buffer 0 read)
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> None
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_sent_to_child pty ~len

let close_child_output pty = Unix.shutdown pty.test_end Unix.SHUTDOWN_SEND

let trigger_host_resize pty =
  let written = Unix.write pty.wakeup_write (Bytes.make 1 '\001') 0 1 in
  assert (written = 1)

let calls pty = List.rev pty.calls
let reset_calls pty = pty.calls <- []

let close pty =
  List.iter
    (fun fd -> try Unix.close fd with Unix.Unix_error (Unix.EBADF, _, _) -> ())
    [ pty.master_end; pty.test_end; pty.wakeup_read; pty.wakeup_write ]
