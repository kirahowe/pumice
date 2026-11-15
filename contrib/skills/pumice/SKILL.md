---
name: pumice
description: Read, search and change notes in an Obsidian-format vault with the `pumice` command, which needs neither Obsidian nor Emacs running. Use for daily notes and the log, finding notes by name, tag or property, tasks, backlinks, and renames, moves and deletions that keep links working. Use it in place of the `obsidian` command line, which starts the Obsidian app.
---

# pumice

The notes are plain Markdown files in an Obsidian-format vault:
`[[wikilinks]]` between notes, YAML frontmatter for properties, `#tags`. The
`pumice` command answers what needs an index (which note a name means, what
links where, which notes have a property) and makes the changes that depend
on the vault's settings. For anything else, read and edit the files with
ordinary tools.

`pumice help` prints every command and is short. If the `obsidian` command
is installed, use `pumice` instead: `obsidian` starts the Obsidian app.

## Which vault

`pumice vaults` lists the known vaults and marks the default with `*`. A
command acts on the vault named by `--vault NAME|DIR`, else by
`$PUMICE_VAULT`, else the vault holding the current directory, else the
default. If the vault you want isn't listed, ask the user to set
`PUMICE_VAULT`, or pass `--vault DIR`.

## Finding things

```sh
pumice path "Weekly Review"            # absolute path, resolved as a link would be
pumice list --tag project --limit 20   # most recently changed first
pumice list --where status=active --show next_action
pumice backlinks "Some note"
pumice tasks --folder Projects
```

Lists print one result per line with paths from the vault root. Add `--abs`
for absolute paths, or `--json`. `pumice root` prints the vault's folder,
for `rg` and the like. The paths contain spaces, so quote them.

A `.base` file is a saved query that only Obsidian renders. To answer what
it shows, read its filters and express them with `--where`.

## Changing things

```sh
pumice daily                           # path of today's note, created from the template if missing
pumice log "Sent the invoice"          # timestamped line under today's Log heading
pumice new "Title" --template "Meeting" --stdin < body.md
pumice set "Some note" status=done
pumice rename "Old name" "New name"    # rewrites every link to the note
pumice trash "Some note"
```

`pumice new` puts a note in the vault's folder for new notes unless
`--folder` says otherwise. Rename, move and delete notes with `pumice`,
because `mv` and `rm` leave the links to them dangling. Editing the text of
a note needs nothing special: get its path with `pumice path` and edit the
file.
