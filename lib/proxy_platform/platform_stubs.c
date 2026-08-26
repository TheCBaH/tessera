/* Narrow C surface for the real Linux Platform.S binding (proxy.md section 1): openpty, the two
   ioctls a PTY needs (TIOCSCTTY, TIOCGWINSZ/TIOCSWINSZ), delivering SIGWINCH to a foreground process
   group, and the signalfd/sigprocmask pair that lets the resize wake-up be observed as ordinary
   descriptor readiness instead of through OCaml's deferred Sys.signal handler dispatch. fork/dup2/
   close/execvp are ordinary Unix module calls done in platform_linux.ml, not here, mirroring how
   Unix.create_process already does fork/dup2/exec in OCaml around a small C surface. */
#define _GNU_SOURCE

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <termios.h>
#include <pty.h>

/* tessera_openpty_stub : int -> int -> int -> int -> (Unix.file_descr * Unix.file_descr)
   Opens a PTY pair and applies the given winsize (rows, columns, x-pixels, y-pixels) atomically, so
   the child never observes an unsized terminal even for one ioctl's worth of time. */
CAMLprim value tessera_openpty_stub(value v_rows, value v_cols, value v_xpixel, value v_ypixel) {
  CAMLparam4(v_rows, v_cols, v_xpixel, v_ypixel);
  CAMLlocal1(result);
  struct winsize ws;
  int master, slave;

  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)Int_val(v_rows);
  ws.ws_col = (unsigned short)Int_val(v_cols);
  ws.ws_xpixel = (unsigned short)Int_val(v_xpixel);
  ws.ws_ypixel = (unsigned short)Int_val(v_ypixel);

  if (openpty(&master, &slave, NULL, NULL, &ws) == -1) uerror("openpty", Nothing);

  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(master));
  Store_field(result, 1, Val_int(slave));
  CAMLreturn(result);
}

/* tessera_setsid_set_ctty_stub : Unix.file_descr -> unit
   Child-side, after fork and before exec: start a new session and make [fd] (the slave) its
   controlling terminal. */
CAMLprim value tessera_setsid_set_ctty_stub(value v_fd) {
  CAMLparam1(v_fd);
  int fd = Int_val(v_fd);

  if (setsid() == -1) uerror("setsid", Nothing);
  if (ioctl(fd, TIOCSCTTY, 0) == -1) uerror("ioctl(TIOCSCTTY)", Nothing);
  CAMLreturn(Val_unit);
}

/* tessera_get_winsize_stub : Unix.file_descr -> (int * int * int * int), i.e. (rows, columns,
   x-pixels, y-pixels) -- [TIOCGWINSZ]. */
CAMLprim value tessera_get_winsize_stub(value v_fd) {
  CAMLparam1(v_fd);
  CAMLlocal1(result);
  struct winsize ws;
  int fd = Int_val(v_fd);

  if (ioctl(fd, TIOCGWINSZ, &ws) == -1) uerror("ioctl(TIOCGWINSZ)", Nothing);

  result = caml_alloc_tuple(4);
  Store_field(result, 0, Val_int(ws.ws_row));
  Store_field(result, 1, Val_int(ws.ws_col));
  Store_field(result, 2, Val_int(ws.ws_xpixel));
  Store_field(result, 3, Val_int(ws.ws_ypixel));
  CAMLreturn(result);
}

/* tessera_set_winsize_stub : Unix.file_descr -> int -> int -> int -> int -> unit -- [TIOCSWINSZ]. The
   kernel raises SIGWINCH to the foreground process group as a side effect exactly when this changes
   the previously applied value; this stub does not decide that, it only applies. */
CAMLprim value tessera_set_winsize_stub(value v_fd, value v_rows, value v_cols, value v_xpixel, value v_ypixel) {
  CAMLparam5(v_fd, v_rows, v_cols, v_xpixel, v_ypixel);
  struct winsize ws;
  int fd = Int_val(v_fd);

  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)Int_val(v_rows);
  ws.ws_col = (unsigned short)Int_val(v_cols);
  ws.ws_xpixel = (unsigned short)Int_val(v_xpixel);
  ws.ws_ypixel = (unsigned short)Int_val(v_ypixel);

  if (ioctl(fd, TIOCSWINSZ, &ws) == -1) uerror("ioctl(TIOCSWINSZ)", Nothing);
  CAMLreturn(Val_unit);
}

/* tessera_notify_winch_stub : Unix.file_descr -> unit
   Sends one SIGWINCH directly to [fd]'s foreground process group, for the "notification arrived but
   resolved geometry is unchanged" case where TIOCSWINSZ alone would not signal the child. */
CAMLprim value tessera_notify_winch_stub(value v_fd) {
  CAMLparam1(v_fd);
  int fd = Int_val(v_fd);
  pid_t pgrp = tcgetpgrp(fd);

  if (pgrp == (pid_t)-1) uerror("tcgetpgrp", Nothing);
  if (kill(-pgrp, SIGWINCH) == -1) uerror("kill", Nothing);
  CAMLreturn(Val_unit);
}

/* tessera_block_sigwinch_signalfd_stub : unit -> Unix.file_descr
   Blocks SIGWINCH in the calling thread and returns a non-blocking, close-on-exec signalfd for it.
   Must be called exactly once, before any child is spawned, by the single thread that will run the
   whole proxy: fork() duplicates the now-blocked mask (the child resets its own mask before exec via
   tessera_reset_child_signals_stub below), and a second unblocked thread could otherwise race the
   signalfd for delivery via SIGWINCH's default disposition (Ignore). Uses sigprocmask, not
   pthread_sigmask, deliberately: this binding never links against systhreads, so the two are
   equivalent here and sigprocmask avoids an otherwise-unneeded -lpthread. */
CAMLprim value tessera_block_sigwinch_signalfd_stub(value v_unit) {
  CAMLparam1(v_unit);
  sigset_t mask;
  int fd;

  sigemptyset(&mask);
  sigaddset(&mask, SIGWINCH);
  if (sigprocmask(SIG_BLOCK, &mask, NULL) == -1) uerror("sigprocmask", Nothing);

  fd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
  if (fd == -1) uerror("signalfd", Nothing);

  CAMLreturn(Val_int(fd));
}

/* tessera_reset_child_signals_stub : unit -> unit
   Child-side, after fork and before exec: clears the inherited signal mask so a spawned program is
   never left with SIGWINCH (or anything else) blocked because the proxy itself blocked it. */
CAMLprim value tessera_reset_child_signals_stub(value v_unit) {
  CAMLparam1(v_unit);
  sigset_t empty;

  sigemptyset(&empty);
  if (sigprocmask(SIG_SETMASK, &empty, NULL) == -1) uerror("sigprocmask", Nothing);
  CAMLreturn(Val_unit);
}
