#!/bin/sh
# Deliberately local-only: updates the checked-in pane captures after a reviewed
# compatibility change.  CI runs the normal comparison mode and rejects this
# script's resulting worktree changes unless they are explicitly committed.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

ERR_TRACE_TEST_MELANGE=true opam exec -- dune build test/proxy_tmux/tmux_test.exe lib/proxy_linux/proxy.exe
TESSERA_PROXY="$repo_root/_build/default/lib/proxy_linux/proxy.exe" \
TESSERA_PROXY_TMUX_FIXTURE="$repo_root/test/proxy_tmux/fixture.sh" \
TESSERA_PROXY_TMUX_WRITE_GOLDENS=1 \
  "$repo_root/_build/default/test/proxy_tmux/tmux_test.exe"

git diff -- test/proxy_tmux/goldens
