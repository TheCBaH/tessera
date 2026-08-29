#!/bin/sh
# Interactive programs launched directly under node-pty by run.js. This is test/proxy_tmux/fixture.sh
# ported to a direct Node PTY runner: there is no tmux layer here to provide wait-for
# channels, so readiness/completion/capture handshakes that fixture.sh signalled through tmux's
# server-side channels are signalled through plain files instead -- the paths are handed down as
# TESSERA_TEST_READY_FILE/TESSERA_TEST_DONE_FILE/TESSERA_TEST_CAPTURED_FILE environment variables.
# Completion also carries a PTY-borne sentinel (TESSERA_TEST_DONE_TITLE, see done_case below) since the
# done file alone races the PTY data channel run.js's Bridge reads from.

scenario=$1
result=$2

wait_for_file() {
  file=$1
  waited=0
  while [ ! -f "$file" ]; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -gt 600 ]; then
      echo "timed out waiting for $file" >&2
      exit 1
    fi
  done
}

done_case() {
  # Signal completion through the PTY itself, not just TESSERA_TEST_DONE_FILE: run.js's Bridge only
  # learns about terminal output asynchronously as PTY data arrives, so a bare done file can be
  # observed by run.js's filesystem poll before the last of this case's real terminal output has
  # actually reached the Bridge. An OSC window-title sequence is invisible to the rendered grid but
  # travels through the same ordered byte stream as everything printed above, so run.js can wait for
  # this exact sentinel in the Bridge's own snapshot and be sure everything earlier is already there.
  printf '\033]0;%s\007' "$TESSERA_TEST_DONE_TITLE"
  : >"$TESSERA_TEST_DONE_FILE"
  # Keep the child (and its PTY) alive until run.js has captured the final Tessera snapshot. In
  # particular, a curses program can restore its terminal mode immediately before this wrapper's own
  # final marker would otherwise be printed.
  wait_for_file "$TESSERA_TEST_CAPTURED_FILE"
}

ready_case() {
  : >"$TESSERA_TEST_READY_FILE"
}

case "$scenario" in
  dialog-menu-submit)
    ready_case
    if dialog --output-fd 3 --menu "Dialog menu" 10 40 2 first First second Second 3>"$result"; then
      :
    else
      printf 'cancel\n' >"$result"
    fi
    done_case
    ;;
  whiptail-menu-cancel)
    ready_case
    if whiptail --output-fd 3 --menu "Whiptail menu" 10 40 2 first First second Second 3>"$result"; then
      :
    else
      printf 'cancel\n' >"$result"
    fi
    printf '\033[2J\033[HWHIPTAIL CANCELLED\n'
    done_case
    ;;
  vt-form-edit)
    printf '\033[2J\033[HFORM: enter value> '
    ready_case
    IFS= read -r value
    printf '%s\n' "$value" >"$result"
    printf '\033[2J\033[HFORM SAVED: %s\n' "$value"
    done_case
    ;;
  vt-scroll-redraw)
    printf '\033[2J\033[HSCROLL START\none\ntwo\nthree\n\033[2A\033[2Kredrawn two\n'
    ready_case
    IFS= read -r _value
    printf 'redrawn\n' >"$result"
    done_case
    ;;
  vt-resize-redraw)
    printf '\033[2J\033[HRESIZE WAITING\n'
    ready_case
    IFS= read -r _value
    dimensions=$(stty size)
    printf '%s\n' "$dimensions" >"$result"
    printf '\033[2J\033[HRESIZE APPLIED: %s\n' "$dimensions"
    done_case
    ;;
  vt-shell-session)
    # This suite's acceptance criteria carries forward terminal-idea.md's "shell use" case: the other
    # scenarios here are all scripted fixtures, not a real interactive shell prompt. This one execs into
    # an actual interactive POSIX shell (not just a script interpreting one), and run.js types a real
    # command at its prompt -- one that itself performs the done/captured handshake -- so the byte stream
    # this exercises is genuine shell prompt/echo/output, not this fixture's own printf.
    ready_case
    export TESSERA_RESULT_PATH="$result"
    export PS1='TESSERA$ '
    exec sh -i
    ;;
  *)
    printf 'unknown fixture scenario: %s\n' "$scenario" >&2
    exit 64
    ;;
esac
