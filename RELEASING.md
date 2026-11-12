# Releasing pumice

A release is the commit on `main` that changes the `Version:` header in
`pumice.el`, with a tag on it.

The commit matters more than the tag. `package-vc-install` and
use-package's `:vc` install the commit that last changed the `Version:`
header, unless someone asks for the newest commit. So the bump has to be the
last commit of the release, after everything the release is meant to
contain, and no other commit should touch that line.

## Before the release

1. Run the checks:

   ```sh
   make
   ```

   Then run the tests once more against the optional packages. `DEPS` is the
   list of directories they are installed in:

   ```sh
   make test DEPS="/path/to/evil /path/to/goto-chg /path/to/consult"
   ```

2. Make sure CI is green on `main`:

   ```sh
   gh run list --branch main --limit 1
   ```

3. If anything a user can see has changed, record the demo again (see below)
   and bring the README up to date.

## Recording the demo

`demo/demo.gif`, the animation at the top of the README, is a recording of a
real session and is made by one command:

```sh
make demo
```

It needs `tmux`, `asciinema` and `agg`, all of which are in Homebrew, and
Emacs 31 or later, because the popup after `[[` is drawn in a terminal. It
takes about a minute. It works on a copy of `demo/vault` and installs the
packages it shows into `demo/.elpa`, so your own notes and configuration are
not involved.

How it works: `demo/record.sh` starts a tmux session on a socket of its
own, runs `asciinema` inside it to capture `demo/session.sh`, and has
`demo/keys.sh` type into that session. `session.sh` is Emacs started with
`demo/init.el`, followed by a few shell commands once Emacs exits. `agg`
then renders the capture to a GIF.

- To change what the demo does, edit `demo/keys.sh`. Each line is a key,
  some typed text, or a pause in seconds.
- To change the notes it starts from, edit `demo/vault`.
- To change how Emacs looks, edit `demo/init.el`.
- To change the size, the speed or the colours, edit the `agg` call at the
  end of `demo/record.sh`.

Watch the result before committing it. A key that reaches Emacs a moment
early, or a command whose keys have changed, leaves the rest of the
recording typing into the wrong place. The top bar in the recording names
each key and the command it ran, which makes that easy to spot.

## The release

1. Change `;; Version:` in `pumice.el` and commit only that:

   ```sh
   commitp -m "Release 0.2.0"
   ```

2. Move `main`, tag the commit and push both:

   ```sh
   jj bookmark set main -r @-
   jj tag set v0.2.0 -r main
   jj git push -b main
   jj git push --tag v0.2.0
   ```

## After the release

1. Watch CI finish on the pushed commit:

   ```sh
   gh run watch
   ```

2. Install it the way a new user would, into an empty Emacs home:

   ```sh
   HOME=$(mktemp -d) emacs --batch -Q --eval "(progn
     (require 'package) (package-initialize) (require 'use-package)
     (use-package pumice :vc (:url \"https://github.com/kirahowe/pumice\")))"
   ```

   It should end with `VC package ‘pumice’ installed`, naming the new
   version and the release commit, and print no compiler warnings.

3. Check the badges at the top of the README: CI passing, and the new
   version.
