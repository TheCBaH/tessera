# Tessera

[![CI status](https://github.com/TheCBaH/tessera/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/TheCBaH/tessera/actions/workflows/build.yml?query=branch%3Amain)
[![Create a Codespace](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new?repo=TheCBaH%2Ftessera&ref=main)

Tessera is a portable, pure OCaml core for decoding terminal output into an
immutable logical screen, plus a Linux transparent proxy built on top of it.
The core is scoped to an xterm-256color core profile and has no I/O,
scheduler, filesystem, JavaScript-binding, or C-stub dependency; it builds on
native OCaml, js_of_ocaml, and Melange.

The core is organised into wrapped Dune components:

- `tessera.foundation` supplies checked portable value types and policy.
- `tessera.model` owns styles, Unicode graphemes, cells, updates, and effects.
- `tessera.decoder` incrementally accepts text and C0 control slices.
- `tessera.renderer` maintains the immutable logical grid and emits lineage
  and generation-aware patches.
- `tessera.terminfo` parses terminfo source/compiled descriptions, compiles
  capability programs, and encodes updates for a declared description.
- `tessera` is the public facade: it also owns the session layer that wires
  decoder, renderer, and terminfo together, and a versioned checkpoint codec
  for portable session persistence.

Scheduler adapters drive `tessera`'s session against a real byte source
without adding an I/O dependency to the core itself:

- `tessera_unix` for blocking `Unix` I/O.
- `tessera_lwt` and `tessera_async` for the Lwt and Core.Async schedulers.
- `tessera.js_adapter` for JavaScript hosts (js_of_ocaml/Melange).

### Linux proxy

`tessera-proxy` (package `tessera_proxy_linux`, Linux-only) transparently
relays a child process's PTY session while maintaining an out-of-band logical
projection of it:

- `tessera_proxy_platform` is the audited PTY/process/signal boundary
  (`openpty`/`forkpty`, `TIOCGWINSZ`/`TIOCSWINSZ`, a blocked-signal
  `signalfd` resize wake-up, and terminfo resource discovery), tested against
  a fake implementation as well as the real Linux binding.
- `tessera_proxy_observer` is the pure, bounded observer ring (traffic,
  resize, and effect records with gap detection and snapshot resync).
- `tessera_proxy_protocol` is the versioned wire schema/codec for that feed.
- `tessera_proxy_linux` composes the above into the resize protocol, the
  byte-exact bidirectional relay, terminal (terminfo) selection with a
  bundled `xterm-256color` fallback, a private local Unix-domain observer
  socket server, and the `tessera-proxy` executable itself.

Run it as `tessera-proxy [command...]` (defaulting to `$SHELL`); it discovers
the host terminal's terminfo resource for `$TERM`, falls back to and
advertises a bundled `xterm-256color` definition when that resource is
missing, unreadable, or not consistent with that declared family, and
exposes its observer feed over a private per-process socket under
`$XDG_RUNTIME_DIR/tessera-proxy/` (or `/tmp` if unset).

`err_trace` is vendored as the `vendor/err_trace` submodule. Clone with
`--recurse-submodules`, or run `git submodule update --init --recursive` after
cloning.

## Compatibility

The declared behavioral family is `xterm-256color`: the documented,
VT/xterm-compatible subset ordinary well-behaved applications expect from
that terminal type, not a promise to emulate every xterm resource, private
extension, or locally configured behavior. It covers UTF-8 text; C0
controls; ESC/CSI/DCS/OSC/APC/PM string framing; cursor movement, editing,
and erasing; margins, tabs, scrolling, origin/wrap modes; SGR including
indexed-256 and RGB color; the line-drawing character set; primary and
alternate screens; cursor visibility and save/restore; bracketed paste,
focus, and SGR mouse modes; window-size changes; titles; and the
status/device queries ordinary xterm-compatible applications use. The proxy
relays bytes outside that subset unchanged, but its own observation of them
is best-effort, not authoritative.

That subset is exercised two ways: the fake-platform contract tests in
`test/proxy_linux` (deterministic, scripted scenarios covering the protocol
rules directly), and the `test/proxy_tmux` compatibility suite, which
launches a real detached `tmux` pane as an independent terminal emulator in
front of `dialog` and `whiptail` (menu navigation, cancel, form editing,
scroll/redraw, and resize/redraw) and compares the proxied pane's captured
output against committed goldens. A deliberate difference from tmux's
rendering is reviewed against this declared subset, not automatically
treated as a bug — tmux is a compatibility oracle here, not the normative
definition of Tessera's rendering semantics. There is no claim of
byte-for-byte or pixel-for-pixel equivalence with any specific terminal
emulator, and no observation of terminal-local state the byte stream itself
doesn't reveal (scrollback viewport, font fallback, text selection,
emulator-specific configuration).

Supported today: the proxy on Linux/x86_64, against the OCaml/build
combinations below. The core (decoder/renderer/terminfo/encoder/checkpoint)
has no proxy-specific dependency and builds on native OCaml, js_of_ocaml, and
Melange wherever those otherwise run; only the scheduler adapters and
`tessera-proxy` itself are platform-restricted, as noted where they're
listed above.

| | OCaml 4.14.3 | OCaml 5.5.0 |
| --- | --- | --- |
| Native build/test, incl. `tessera-proxy` + its compatibility suite (Linux/x86_64) | CI | CI |
| js_of_ocaml build (`make jsoo`) | CI | CI |
| Melange build (`make melange`) | CI | CI |

## Development

The devcontainer uses OCaml 4.14.3 by default. CI builds on x86_64 with OCaml
4.14.3 and 5.5.0.

```sh
make build       # build every Dune target
make test        # run tests and promote accepted expect outputs
make format      # format sources
make format-check
make precommit   # format, build, test, jsoo, melange, format-check, git diff --check
```

The Linux proxy's compatibility tests drive real `tmux`, `dialog`, and
`whiptail` binaries (provisioned by the devcontainer image); `make test`
runs them alongside the rest of the suite on Linux.

### Reproducibility

What's pinned to an exact version today:

- The OCaml compiler: 4.14.3 and 5.5.0, matching the CI matrix.
- `ocamlformat`, at 0.28.1 (`.devcontainer/devcontainer.json`).
- `err_trace` and the vendored Unicode libraries (`uucp`/`uuseg`/`uutf`), each
  a git submodule pinned to an exact commit under `vendor/`.
- The devcontainer's Debian base image, pinned by digest in
  `.devcontainer/Dockerfile` (see that file for how to refresh it alongside
  the tag).
- Every other opam dependency of `tessera_unix`, `tessera_lwt`,
  `tessera_async`, and the `tessera_proxy_*` packages, in the `*.opam.locked`
  files at the repository root (`opam install --locked <pkg>.opam.locked`).
  Regenerate them against the default (4.14.3) switch with `make opam-lock`
  after a dependency change; they are not separately generated for 5.5.0.
  `tessera.opam` has no lock file of its own: its only non-test dependency is
  the vendored, submodule-pinned `err_trace` above, which opam never installs
  as a package in this project's build.

CI's `verify repository is unchanged` step (`make pristine`) additionally
catches any drift a build or test run leaves in tracked, generated files
(the `*.opam` files `dune build` regenerates, promoted expect-test output).
