# Releasing pumice

A release is the commit on `main` that changes the `Version:` header in
`pumice.el`, a tag on that commit, and a GitHub release for the tag.

The commit matters more than the tag. Emacs treats the commit that last
changed the `Version:` header as the latest release. By default, use-package's
`:vc` installs that commit, and `package-vc-install` installs it when you ask
for the last release. The version bump must therefore be the last commit of
the release, after everything the release should contain, and no other commit
should change that line.

The GitHub release holds `demo.gif`, the animation at the top of the README.
The GIF isn't committed, because every recording would add about 640 KB to
the history that each new install clones. The README links to
`releases/latest/download/demo.gif`, which GitHub redirects to the file
attached to the latest release.

## Before the release

1. Run the checks:

   ```sh
   make
   ```

2. Run the tests again against the optional packages. Set `DEPS` to the
   directories where those packages are installed:

   ```sh
   make test DEPS="/path/to/evil /path/to/goto-chg /path/to/consult"
   ```

3. Check that CI passes on `main`:

   ```sh
   gh run list --branch main --limit 1
   ```

4. Record the demo again, so that the animation shows this release:

   ```sh
   make demo
   ```

5. Watch the new `demo/demo.gif` in a browser, from start to finish.
   "Record the demo" below describes what a bad recording looks like.

6. If the demo shows something that it didn't show before, update the alt
   text of the image at the top of `README.md` and commit the change. The
   alt text lists what the demo shows.

## The release

1. Commit the change to `;; Version:` in `pumice.el`, with nothing else in
   the commit:

   ```sh
   commitp -m "Release 0.2.0"
   ```

2. Move `main` to that commit, tag it, and push the bookmark and the tag:

   ```sh
   jj bookmark set main -r @-
   jj tag set v0.2.0 -r main
   jj git push -b main
   jj git push --tag v0.2.0
   ```

3. Create the GitHub release and attach the recording:

   ```sh
   gh release create v0.2.0 demo/demo.gif --verify-tag --title 0.2.0 --generate-notes
   ```

   `--generate-notes` writes notes that link to the changes since the
   previous release. The file must be named `demo.gif`. A latest release
   without that file leaves a broken image at the top of the README.

## After the release

1. Wait for CI to finish on the pushed commit:

   ```sh
   gh run watch
   ```

2. Install the release the way a new user would, into an empty Emacs home:

   ```sh
   HOME=$(mktemp -d) emacs --batch -Q --eval "(progn
     (require 'package) (package-initialize) (require 'use-package)
     (use-package pumice :vc (:url \"https://github.com/kirahowe/pumice\")))"
   ```

   The output should end with `VC package ‘pumice’ installed`, name the new
   version and the release commit, and contain no compiler warnings.

3. Open the README on GitHub. Check that the animation is the new
   recording, and that the badges show CI passing and the new version.

## Record the demo

The animation at the top of the README is a recording of a real session. To
make it, run:

```sh
make demo
```

The command writes `demo/demo.gif`, which Git ignores. It takes about a
minute and needs the following:

- `tmux`, `asciinema`, and `agg`, which are all in Homebrew.
- Emacs 31 or later, because the popup after `[[` is drawn in a terminal.

The recording works on a copy of `demo/vault` and installs the packages it
shows into `demo/.elpa`, so it doesn't touch your own notes or
configuration.

`demo/record.sh` starts a tmux session on its own socket and runs
`asciinema` in that session to capture `demo/session.sh`. It also has
`demo/keys.sh` type into the session. `session.sh` starts Emacs with
`demo/init.el`, then runs a few shell commands after Emacs exits. Finally,
`agg` renders the capture as a GIF.

Each kind of change has its own file:

- To change what the demo does, edit `demo/keys.sh`. Each line is a key,
  some typed text, or a pause in seconds.
- To change the notes it starts from, edit `demo/vault`.
- To change how Emacs looks, edit `demo/init.el`.
- To change the size, the speed, or the colours, edit the `agg` call at the
  end of `demo/record.sh`.

Watch the result before you attach it to a release. If a key reaches Emacs a
moment early, or a command's keys have changed, the rest of the recording
types into the wrong place. The bar at the top of the recording names each
key and the command it ran, so this kind of mistake is easy to spot.

To replace the recording on a release that already exists, upload it again:

```sh
gh release upload v0.2.0 demo/demo.gif --clobber
```
