#!/bin/bash
# Types the demo into the tmux session at a pace someone can follow.
# demo/record.sh runs this.  Each line is a key, some typed text, or a
# pause in seconds; the comments say what the viewer should be seeing.
T() { tmux -L pumice-demo "$@"; }
pause() { perl -e 'select(undef, undef, undef, $ARGV[0])' "$1"; }
key() { T send-keys "$@"; }
say() { local s=$1 i; for ((i = 0; i < ${#s}; i++)); do T send-keys -l "${s:$i:1}"; pause 0.075; done; }

pause 2.2                                     # the Home note
key C-c n n; pause 0.9; say "gar"; pause 1.8  # jump to a note, with a live preview
key Enter; pause 1.3
key C-c n ]; pause 0.8                        # move to the next link
key C-c C-o; pause 1.8                        # follow it
key M-,; pause 1.2                            # and come back
key C-c n b; pause 2.4                        # the backlinks panel
key C-c n B; pause 0.5
key n; pause 0.22; key n; pause 0.22; key n; pause 0.22; key n; pause 0.9
key l; pause 2.2                              # turn the unlinked mention into a link
key C-c n e; pause 1.9                        # the folder tree
key n; pause 0.6; key Enter; pause 1.4        # open Kitchen shelves from it
key M-\>; pause 0.4; key Enter
say "Same oak as the beds in the [["; pause 1.6   # note names pop up after [[
say "gar"; pause 1.1; key Enter; pause 1.0; say "."; pause 0.5
key C-x C-s; pause 1.3
key C-c n e; pause 0.8; key p; pause 0.7      # back to the tree, up to Garden plan
key r; pause 1.0; key M-BSpace; pause 0.4; say "2027"; pause 0.9
key Enter; pause 2.6                          # renamed, and three links rewritten
key C-c n a; pause 0.8; say "Ordered the seeds"; pause 0.6; key Enter; pause 1.4
key C-c n d; pause 2.8                        # today's note, made from the template
key C-x C-c                                   # the shell part then runs by itself
