#!/bin/sh
# What the recording shows: Emacs in the demo vault, then, once Emacs
# exits, a few commands in the shell.  demo/record.sh runs this inside
# asciinema and demo/keys.sh types into it.
demo=$(cd "$(dirname "$0")" && pwd)
export TERM=xterm-256color COLORTERM=truecolor

emacs -nw -Q -l "$demo/init.el" "$PUMICE_DEMO_VAULT/Home.md"

pumice() { "$demo/../bin/pumice" "$@"; }
nap() { perl -e 'select(undef, undef, undef, $ARGV[0])' "$1"; }
run() { # show a prompt, type the command out, then run it for real
  printf '\033[1;32m$\033[0m '
  nap 0.6
  perl -e '$| = 1; for (split //, $ARGV[0]) { print; select(undef, undef, undef, 0.045) }' "$1"
  nap 0.5
  printf '\n'
  eval "$1"
  nap "${2:-1.6}"
}

cd "$PUMICE_DEMO_VAULT" || exit 1
printf '\033[2J\033[H'
printf '\033[2m# the same index from the shell, with no Emacs running\033[0m\n'
nap 1.0
run 'pumice backlinks "Garden 2027"' 2.4
run 'pumice tasks' 3.0
