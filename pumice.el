;;; pumice.el --- Obsidian vaults without Obsidian -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kira Howe

;; Author: Kira Howe <email@kirahowe.com>
;; URL: https://github.com/kirahowe/pumice
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: outlines, hypermedia, text
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Pumice works on Obsidian vaults where they are.  Notes stay plain
;; Markdown with [[wikilinks]], and each vault's own .obsidian settings
;; decide where daily notes, templates and new notes go, so Obsidian on a
;; phone or another computer keeps working on the same files.
;;
;; To set it up:
;;
;;   (pumice-global-mode 1)
;;   (keymap-global-set "C-c n" 'pumice-command-map)
;;
;; `pumice-global-mode' turns on `pumice-mode' in every Markdown file that
;; lives in a vault.  The vaults are the ones Obsidian knows about, or the
;; ones named in `pumice-vault-directories'.  `pumice-command-map' holds
;; the commands: jump to a note, search, daily notes, the folder tree, the
;; backlinks panel, renaming and the rest.
;;
;; Emacs 29.1 is all it needs.  It uses consult, corfu or company,
;; markdown-mode and ripgrep when they are installed.  pumice-evil.el adds
;; vim keys for evil, and bin/pumice is a command line that works without
;; a running Emacs.
;;
;; Loading this file loads the whole package, which is made of:
;;
;;   pumice-core.el      finding vaults, the note index, resolving links
;;   pumice-commands.el  the note switcher, links, daily notes, templates
;;   pumice-refactor.el  renaming, extracting and deleting notes
;;   pumice-ui.el        `pumice-mode' and the backlinks panel
;;   pumice-tree.el      the folder tree
;;   pumice-cli.el       the command line, which this file does not load

;;; Code:

(require 'pumice-core)
(require 'pumice-commands)
(require 'pumice-refactor)
(require 'pumice-ui)
(require 'pumice-tree)

(defvar-keymap pumice-command-map
  :doc "The pumice commands, for a prefix key of your choosing.
Nothing binds this map by default.  For example:

  (keymap-global-set \"C-c n\" \\='pumice-command-map)"
  "n" #'pumice-find
  "f" #'pumice-find
  "s" #'pumice-search
  "/" #'pumice-search
  "#" #'pumice-find-by-tag
  "h" #'pumice-home
  "z" #'pumice-random
  "v" #'pumice-switch-vault
  ;; Daily notes
  "d" #'pumice-daily
  "y" #'pumice-daily-yesterday
  "t" #'pumice-daily-tomorrow
  "D" #'pumice-daily-date
  "<" #'pumice-daily-previous
  ">" #'pumice-daily-next
  "a" #'pumice-log
  ;; Writing
  "c" #'pumice-capture
  "i" #'pumice-insert-link
  "T" #'pumice-insert-template
  "x" #'pumice-extract
  "r" #'pumice-rename
  "X" #'pumice-trash
  ;; At point
  "RET" #'pumice-follow
  "[" #'pumice-previous-link
  "]" #'pumice-next-link
  ;; Looking around
  "e" #'pumice-tree
  "b" #'pumice-panel-toggle
  "B" #'pumice-panel-focus
  "O" #'pumice-open-in-obsidian)

;; As a command too, so that the map can be bound by name, and from an
;; init file before the package has loaded.
;;;###autoload (autoload 'pumice-command-map "pumice" nil t 'keymap)
(fset 'pumice-command-map pumice-command-map)

(provide 'pumice)
;;; pumice.el ends here
