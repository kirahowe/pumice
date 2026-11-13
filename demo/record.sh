#!/bin/sh
# Record demo/demo.gif, the animation at the top of the README.
#
# It needs tmux, asciinema and agg, which are all in Homebrew, and an Emacs
# that can draw popups in a terminal, which means Emacs 31 or later.  Run it
# with `make demo'.  It takes about a minute, and nothing in it touches your
# own Emacs configuration or your own vaults.
#
#   demo/vault      the notes the demo starts from
#   demo/init.el    the Emacs setup: pumice, the optional packages, a theme
#   demo/session.sh what is recorded: Emacs, then a few shell commands
#   demo/keys.sh    the keys typed into it, with their timing
set -e

demo=$(cd "$(dirname "$0")" && pwd)
cols=116
rows=30

for tool in tmux asciinema agg emacs; do
  if ! command -v "$tool" >/dev/null; then
    echo "record.sh: $tool is not installed" >&2
    exit 1
  fi
done

# Install the optional packages first, so the recording does not show it.
emacs --batch -l "$demo/init.el"

# The demo renames and edits notes, so it works on a copy.  The folder's
# name is the vault's name, which the folder tree shows.
work=$(mktemp -d)
export PUMICE_DEMO_VAULT="$work/Notes"
cp -R "$demo/vault" "$PUMICE_DEMO_VAULT"

# tmux is how the keys reach Emacs.  It gets a server of its own, on its own
# socket, which goes away when the session ends.
tmux -L pumice-demo kill-server 2>/dev/null || true
tmux -L pumice-demo new-session -d -x "$cols" -y "$rows" \
  "asciinema rec --quiet --overwrite --window-size ${cols}x${rows} \
     -c '$demo/session.sh' '$work/demo.cast'"
"$demo/keys.sh"

# The shell part of the session runs by itself.  Wait for it to finish.
while tmux -L pumice-demo has-session 2>/dev/null; do
  perl -e 'select(undef, undef, undef, 0.5)'
done

# The colours are the theme's own (One Dark), so that the shell part has the
# same background as Emacs.  The speed-up keeps the whole thing near 40
# seconds while the keys are still typed at a pace that looks human.
#
# The font is twice the size it is read at.  GitHub fits the picture to the
# width of the README, and a high-density screen has two pixels for each
# point of that width, so a picture drawn at reading size is stretched and
# its text blurs.  Drawn at double size, it is only ever scaled down.  The
# resvg renderer makes the same picture as the default one in a file about
# a quarter smaller, and takes about ten seconds longer.
one_dark=282c34,abb2bf,282c34,e06c75,98c379,e5c07b,61afef,c678dd,56b6c2,abb2bf
one_dark=$one_dark,5c6370,e06c75,98c379,e5c07b,61afef,c678dd,56b6c2,ffffff
agg --quiet --theme "$one_dark" --renderer resvg \
    --font-family "JetBrainsMono Nerd Font Mono,JetBrains Mono,Menlo" \
    --font-size 28 --line-height 1.3 --fps-cap 15 --speed 1.3 \
    --idle-time-limit 2 --last-frame-duration 4 \
    "$work/demo.cast" "$demo/demo.gif"

rm -rf "$work"
ls -lh "$demo/demo.gif" | awk '{print "wrote demo/demo.gif, " $5}'
