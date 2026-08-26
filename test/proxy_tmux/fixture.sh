#!/bin/sh
# Interactive programs launched under tmux -> tessera-proxy by tmux_test.ml.
# Each case writes a completion/result file and signals the isolated tmux server,
# so the test never has to guess when curses output has settled.

scenario=$1
result=$2

done_case() {
  tmux wait-for -S "$TESSERA_TEST_DONE"
  # Keep the proxy and its PTY alive until tmux_test has captured the final
  # screen.  In particular, a curses program can restore its terminal mode
  # immediately before the wrapper prints its final marker.
  tmux wait-for "$TESSERA_TEST_CAPTURED"
}

ready_case() {
  tmux wait-for -S "$TESSERA_TEST_READY"
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
  *)
    printf 'unknown fixture scenario: %s\n' "$scenario" >&2
    exit 64
    ;;
esac
