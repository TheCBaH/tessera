(* A tiny purpose-built child for layer-4 integration tests (proxy.md "Testing"): prints its
   TIOCGWINSZ result on startup and again on every SIGWINCH, then echoes stdin to stdout byte-for-byte
   until EOF. Deliberately a plain OCaml program using Sys.signal, not Tessera_proxy_platform_linux's
   own signalfd machinery -- it plays the role of an ordinary application under the proxy, which is
   exactly the process the proxy must never install an OCaml signal handler in place of. *)

(* Linux's SIGWINCH signal number; not exposed by Stdlib.Sys (unlike sigchld, sigusr1, ...). This
   helper is only ever built under this package's (enabled_if (= %{system} linux)) gate. *)
let sigwinch = 28

module Platform_linux = Tessera_proxy_platform_linux.Platform_linux

let print_winsize () =
  match Platform_linux.physical_winsize () with
  | Ok winsize -> Format.printf "winsize %a@." Tessera_proxy_platform.Winsize.pp winsize
  | Error error -> Format.printf "winsize-error %a@." Platform_linux.pp_error error

let () =
  Sys.set_signal sigwinch (Sys.Signal_handle (fun (_ : int) -> print_winsize ()));
  (* The first line is the test harness's readiness handshake.  Emit it only after
     the SIGWINCH handler is installed, otherwise a resize issued immediately after
     that line can be delivered while SIGWINCH still has its default disposition. *)
  print_winsize ();
  let buffer = Bytes.create 4096 in
  let rec loop () =
    match Unix.read Unix.stdin buffer 0 (Bytes.length buffer) with
    | 0 -> ()
    | count ->
        let written = ref 0 in
        while !written < count do
          written := !written + Unix.write Unix.stdout buffer !written (count - !written)
        done;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()
