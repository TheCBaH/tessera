# Tessera: ncurses implementation review

This is a comparator review, not a proposed dependency. ncurses is a mutable
application-facing terminal UI library with process-global and screen-local
state. Tessera is a portable functional protocol/model library plus a
transparent proxy, so its API and ownership boundaries remain different.

Review basis: ncurses-snapshots commit
[`6d481e5`](https://github.com/ThomasDickey/ncurses-snapshots/tree/6d481e5)
(snapshot label `v6_6_20260815`, cloned from
`https://github.com/ThomasDickey/ncurses-snapshots` on 2026-08-22).
Linux/POSIX documentation, not ncurses, remains the authority for OS behavior.

## Resize delivery and deferred work

The `SIGWINCH` handler does not resize windows or query the terminal. It sets
a pending flag and, in the threaded configuration, interrupts the read thread;
see [`lib_tstp.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/tty/lib_tstp.c#L303-L316).
Later input processing observes the flag, updates screen size, and retrieves a
queued resize indication; see
[`lib_getch.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/base/lib_getch.c#L581-L594).

This validates the rule that a signal handler is only a wake-up/flagging path.
Model transitions, allocation, I/O, and observer publication belong in the
ordinary serialized loop, not in the handler.

The deferred update explicitly distinguishes a changed size from an unchanged
size with a pending resize signal. In the latter case it queues `KEY_RESIZE`
so the application can still observe the notification; see
[`lib_setup.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/tinfo/lib_setup.c#L619-L655).
This is direct evidence for preserving same-geometry resize notices in Tessera:
the child application needs a `SIGWINCH` even if the final dimensions equal the
previous dimensions, and the observer needs an explicit full-refresh event.

`resizeterm` documents that it reallocates state and must not normally run in a
signal handler. On an actual size change it marks physical contents unknown
and pushes `KEY_RESIZE`; see
[`resizeterm.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/base/resizeterm.c#L462-L529).
The applicable Tessera consequence is full damage/snapshot after every
observed resize notice. Reallocating arbitrary application windows and
injecting `KEY_RESIZE` are ncurses-specific behavior, not proxy behavior.

## Geometry authority and recovery

ncurses can combine terminfo defaults, TTY ioctl results, and optional `LINES`
and `COLUMNS` environment overrides; see
[`lib_setup.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/tinfo/lib_setup.c#L460-L583).
This configurability is appropriate for an application UI library but is not a
safe authority model for a transparent PTY proxy. The proxy must use the host
TTY's actual `winsize`, forward it to the child PTY, and leave the child
environment untouched. Applications and libraries may then apply their own
documented environment policy after receiving `SIGWINCH`.

The library also checks for size changes when returning to active terminal use,
not only at signal receipt; see
[`tty_update.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/tty/tty_update.c#L809-L818).
This motivates proxy reconciliation on attach/resume/reattachment boundaries,
where a notification may have been coalesced or missed.

## State and portability boundaries

The source keeps resize callbacks on each mutable `SCREEN` object and uses
global locks/state for non-reentrant configurations; for example,
[`lib_set_term.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/base/lib_set_term.c#L593-L603)
and
[`resizeterm.c`](https://github.com/ThomasDickey/ncurses-snapshots/blob/6d481e5/ncurses/base/resizeterm.c#L351-L445).
That confirms the value of isolating screen transition logic from TTY discovery,
but not the mutable/global implementation strategy. Tessera retains immutable
renderer states, explicit session successors, and a scheduler-free core.

ncurses uses host terminfo initialization and capability access (`setupterm`,
`tigetstr`) as part of its native terminal integration. Tessera retains its
in-tree bounded parser and adapter-owned terminfo discovery so that the core
does not need host files, locale, C globals, or terminal descriptors.

## Decisions retained after review

| Concern | Tessera decision |
| --- | --- |
| Signal handler | Wake or record pending work only; defer all stateful work to the serialized adapter loop. |
| Equal dimensions | Preserve the observed notification, notify the child process group, and publish a full projection refresh. |
| Resize damage | Treat terminal contents as requiring a full observer projection after a resize notice. |
| Geometry source | Use the host TTY `winsize`; do not use or rewrite `LINES`/`COLUMNS`. |
| Lifecycle recovery | Re-query/reconcile at attach, resume, reattachment, and relay-resume boundaries. |
| Application event | The child observes the kernel's `SIGWINCH`, not synthetic terminal input bytes or a library-specific key code. |
| Core state | Keep resize transition pure and immutable; no global signal/TTY state in portable packages. |
| Terminfo | Keep host discovery in adapters and parsing in the portable core. |
