# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tessera is a portable, pure OCaml core that decodes terminal output (xterm-256color subset) into
an immutable logical screen, plus a Linux transparent PTY proxy built on top of it. The core has
no I/O, scheduler, filesystem, JS-binding, or C-stub dependency and builds under native OCaml,
js_of_ocaml, and Melange from the same sources.

Read `README.md` for the package/component overview and the compatibility contract
(`xterm-256color` subset, what "compatible" does and doesn't mean here). Read `test/README.md`
before touching anything under `test/` — it documents the full test layout, the Dune
dependency-isolation rules between component suites, and several non-obvious cross-runtime
fixtures; don't duplicate that detail from memory, go re-read it.

## Commands

```sh
make build          # build every Dune target
make test           # run tests (dune runtest), promoting accepted expect outputs
make format          # dune fmt
make format-check
make jsoo            # js_of_ocaml build (@jsoo)
make melange         # Melange build (@tessera-melange)
make check           # format build test jsoo melange format-check
make precommit       # check + git diff --check
make pristine        # fails if the tree has any uncommitted/generated drift (what CI checks)
```

Everything above runs through `opam exec -- dune ...` with `ERR_TRACE_TEST_MELANGE=true` set (see
the `Makefile`) — don't invoke `dune` directly without that env var or targets that depend on
`err_trace`'s Melange test path will fail to build.

Run a single test layer directly with dune, e.g.:

```sh
dune build @test-decoder
dune build @test-renderer
dune build @test-decoder-corpus
```

`test/README.md`'s table lists every layer's alias (`@test-<name>`).

Opt-in suites, not part of `make check`/`make test` because they need Node/network/a browser (see
each Makefile target's comment for exact prerequisites and what they cover):

```sh
make node-pty-install && make test-node-pty        # real Linux PTY through jsoo/Melange via node-pty
make playwright-install && make test-web-render     # browser driver + Playwright structural/screenshot suite
```

A few Make targets regenerate committed golden/fixture files and are explicit developer commands —
never run in CI, always review the diff before committing: `make opam-lock`,
`make node-pty-capture-traces`, `make web-render-gen-fixtures`, `make web-render-gen-goldens`,
`make playwright-update-screenshots`, and `test/proxy_tmux/regenerate_goldens.sh`.

The devcontainer defaults to OCaml 4.14.3; CI matrixes 4.14.3 and 5.5.0 on x86_64.

## Repository conventions

- **Top-level `.md` files are not tracked in git, except `README.md`.** Scratch/planning docs
  (design notes, review write-ups, milestone plans) go at the repo root as untracked files during
  work but must not be `git add`ed. Multiple untracked `*.md` files at the root you'll see in
  `git status` (e.g. `milestones.md`, `*-plan.md`, `httpun-ws-*.md`) are exactly this kind of
  working-notes debris — expected, not a repo mistake.
- **Commit messages must be concise and to the point** — a short summary line plus, if needed,
  one or two brief paragraphs of body. No blow-by-blow narration.
- **Never reference a file that isn't tracked in this repo, in a commit message or a code
  comment.** That includes the untracked top-level `.md` scratch files above: a reference to one
  goes stale the moment the file is cleaned up, since nothing tracks that it ever existed. If a
  rationale is worth keeping permanently, put it in the comment/commit message itself, or in a
  tracked file, not behind a pointer to an untracked one.
- Golden/fixture regeneration commands (listed above) are always developer-invoked, never part of
  CI, and their diffs must be reviewed before committing.
- `make pristine` (part of CI) fails the build if any tracked, generated file drifts — including
  `*.opam` files, which `dune build` regenerates from `dune-project`. Don't hand-edit `*.opam`
  files; edit the `(package ...)` stanza in `dune-project` instead.
- `err_trace` and the vendored Unicode/JSON libraries (`uucp`, `uuseg`, `uutf`,
  `vendor/json_codec/{jsont,bytesrw}`) are git submodules under `vendor/`. Clone with
  `--recurse-submodules` or run `git submodule update --init --recursive`.
- Dependency versions are pinned three ways: the OCaml compiler (4.14.3/5.5.0, CI matrix),
  `ocamlformat` (0.28.1, in `.devcontainer/devcontainer.json`), and everything else via
  `*.opam.locked` files at the repo root (regenerate with `make opam-lock` after a dependency
  change; install with `opam install --locked <pkg>.opam.locked`).
- The devcontainer's opam features pin a patched `httpun-ws` fork
  (`.devcontainer/devcontainer.json`'s `pin-packages`) working around a real upstream hang in its
  frame-queue read loop, documented in that same file's comment. Don't "fix" this pin back to
  upstream `httpun-ws` without checking whether that bug has actually been released fixed
  upstream.

## Architecture

### Core pipeline (no I/O)

Wrapped Dune components under `lib/`, each independently testable:

- `foundation` — checked portable value types and policy.
- `model` — styles, Unicode graphemes, cells, updates, effects.
- `decoder` — incrementally accepts text and C0 control byte slices.
- `renderer` — maintains the immutable logical grid; emits lineage- and generation-aware patches.
- `terminfo` — parses terminfo source/compiled descriptions, compiles capability programs, encodes
  updates for a declared description.
- `tessera` (facade, in `lib/` root-level modules) — the public API; also owns the session layer
  wiring decoder → renderer → terminfo together, plus a versioned checkpoint codec for session
  persistence.

Round trip: `Patch → Repaint.compile → Encoder.encode → Decoder.feed → Renderer.apply`
(`test/integration` exercises this end to end through the public facade only).

### Scheduler adapters

Each adapter serialises byte reads and validated resize requests through `Tessera.Session.ingest`,
holding its lock only around the brief session mutation, never around the blocking/pending read
itself, so a concurrent resize is never stuck behind an in-flight read:

- `unix_adapter` (`tessera_unix`) — blocking `Unix` I/O on a background thread + `Mutex.t`.
- `lwt_adapter` (`tessera_lwt`) — `Lwt_unix` + `Lwt_mutex.t`.
- `async_adapter` (`tessera_async`) — `Async.Reader` + `Async.Throttle.Sequencer.t`.
- `js_adapter` (`tessera.js_adapter`) — JSOO/Melange; no descriptor, no scheduler, so `push`/
  `resize`/`finish` are plain synchronous functions returning their outcome directly (the host's
  own event callback is the entire integration). Has zero backend-specific code, so it compiles
  unchanged in `byte` and `melange` modes.

All four are proven against one shared scenario fixture in `test/conformance` (see
`test/README.md` for exactly what each adapter's suite covers and why).

### Web rendering projection

`lib/web_rendering` turns a `Tessera` outcome into a wire-portable frame (`Web_frame.of_outcome`),
projected to either an HTML or Canvas JSON envelope (`Web_html`/`Web_canvas`/`Web_json`), byte-
identical across native/JSOO/Melange (proven by `test/web_rendering_codec`,
`test/web_bridge_equivalence`). `lib/web_bridge` wraps the whole pipeline (adapter ingest →
`Web_frame` → projection → JSON) behind one `create`/`push`/`resize`/`finish` surface with a
target fixed for its lifetime, matching how a browser page mounts exactly one target; it has no
backend-specific type in its signature either.

`web/` at the repo root is the shipped, framework-free browser side (plain `<script>` tags, no
bundler): `tessera-driver.js`'s `TesseraDriver` is the resync/rollback-safe state machine that
consumes that JSON stream (BigInt-tracked lineage/generation fencing, reset-on-gap recovery — see
`test/README.md`'s "Transport" discussion for the exact fencing rules before touching it);
`tessera-html-target.js` is the DOM target; `tessera.css` is the versioned stylesheet (CSS Grid +
`subgrid`, a static 256-colour palette as custom properties).

Canonical test oracle: real dialog/whiptail/shell PTY output is captured once as JSON traces
(`test/node_pty/traces/*.json`, via `make node-pty-capture-traces`) and replayed natively — no PTY,
no Node — by `test/web_rendering_traces` on every ordinary build.

### Linux proxy

`lib/proxy_*` composes into the `tessera-proxy` executable (package `tessera_proxy_linux`,
Linux-only):

- `proxy_platform` — the audited PTY/process/signal boundary (`openpty`/`forkpty`,
  `TIOCGWINSZ`/`TIOCSWINSZ`, blocked-signal `signalfd` resize wake-up, terminfo resource
  discovery), tested against both a fake implementation and the real Linux binding.
- `proxy_observer` — pure, bounded observer ring (traffic/resize/effect records, gap detection,
  snapshot resync).
- `proxy_protocol` — versioned wire schema/codec for the observer feed.
- `proxy_web_protocol` — versioned JSON (Jsont) control-channel protocol for
  `tessera.proxy-web`'s WebSocket session channel.
- `proxy_web_publisher` — pure attach/reset/delta/backpressure state machine turning a
  `Tessera.outcome` into per-client, per-target `web_rendering` JSON, shared by every WebSocket
  client attached to a target.
- `proxy_linux` — wires `tessera_lwt`, `proxy_platform`, `proxy_observer`, `proxy_protocol`,
  `proxy_web_protocol`, `proxy_web_publisher`, and `web_rendering` into the resize protocol, the
  byte-exact bidirectional relay, terminal(terminfo) selection with a bundled `xterm-256color`
  fallback, a private local observer Unix-domain socket, an HTTP/WebSocket server
  (`httpun`/`httpun-ws` + Lwt) serving the `web/` assets and live frames, and the `tessera-proxy`
  executable itself.

Run as `tessera-proxy [command...]` (defaults to `$SHELL`). It discovers the host terminfo
resource for `$TERM`, falls back to (and advertises) a bundled `xterm-256color` definition when
that's missing/unreadable/inconsistent, and exposes its observer feed over a private per-process
socket under `$XDG_RUNTIME_DIR/tessera-proxy/` (or `/tmp`).

The devcontainer pins a patched `httpun-ws` fork (see Repository conventions above) — a real
upstream hang, not a local workaround to remove casually.

### Compatibility testing strategy

Two independent layers exercise the declared `xterm-256color` subset (see README.md's
"Compatibility" section for what that subset covers and explicitly does not promise):

1. `test/proxy_linux` — deterministic, scripted fake-platform contract tests.
2. `test/proxy_tmux` — launches a real detached `tmux` pane as an independent terminal emulator in
   front of `dialog`/`whiptail`, compares proxied output against committed goldens. tmux is a
   compatibility *oracle* here, not Tessera's normative rendering definition — a deliberate
   difference is reviewed against the declared subset, not automatically treated as a bug.

`test/node_pty` ports the same case set through a real Linux PTY driving the actual generated
JSOO/Melange `js_adapter` build via node-pty, asserting Tessera's own logical-screen snapshot
(not a visual capture) — this is what caught a real Unicode width bug (`Emoji` vs.
`Emoji_Presentation`; see `test/README.md`).
