;;; pumice-evil.el --- Vim keys for pumice, for evil users -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kira Howe

;; Author: Kira Howe <email@kirahowe.com>
;; URL: https://github.com/kirahowe/pumice
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of pumice.  It is free software: you can redistribute
;; it and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.  It comes with no
;; warranty; see the file LICENSE for the details.

;;; Commentary:

;; Optional.  Nothing in pumice loads this file, and pumice works without
;; evil.  To have the keys below, put this in your init file:
;;
;;   (require 'pumice-evil)
;;
;; It can go before or after evil loads.  The keys appear once evil has.
;;
;; In a note, in normal state:
;;
;;   RET         follow the link or tick the checkbox at point
;;   S-RET, gF   follow the link in another window
;;   gf          follow the link
;;   ]l  [l      the next and previous link
;;   ]d  [d      the next and previous daily note
;;
;; The backlinks panel and the folder tree start in motion state, so j and
;; k move.  RET, o, q and gr work in both.  In the panel L links an
;; unlinked mention.  In the tree h and l step out of and into folders, za,
;; zM and zR fold, and s, a and r sort, add and rename.
;;
;; No leader key is bound, because leaders differ.  Put `pumice-command-map'
;; on yours:
;;
;;   (evil-define-key 'normal 'global (kbd "<leader>n") 'pumice-command-map)

;;; Code:

(require 'pumice)

(declare-function evil-ret "evil-commands")
(declare-function evil-define-key* "evil-core")
(declare-function evil-define-minor-mode-key "evil-core")
(declare-function evil-set-initial-state "evil-core")

(defun pumice-evil-ret (&optional count)
  "Follow the link or tick the checkbox at point, else move down COUNT lines."
  (interactive "p")
  (or (pumice-follow) (evil-ret count)))

(defun pumice-evil--bind ()
  "Bind the vim keys.  Run once evil has loaded."
  ;; These hang off the minor mode, so they only exist in notes.
  (evil-define-minor-mode-key 'normal 'pumice-mode
    (kbd "RET") #'pumice-evil-ret
    (kbd "<S-return>") #'pumice-follow-other-window
    "gf" #'pumice-follow
    "gF" #'pumice-follow-other-window
    "]l" #'pumice-next-link
    "[l" #'pumice-previous-link
    "]d" #'pumice-daily-next
    "[d" #'pumice-daily-previous)

  (evil-set-initial-state 'pumice-panel-mode 'motion)
  (evil-define-key* 'motion pumice-panel-mode-map
    (kbd "RET") #'pumice-panel-visit
    "o" #'pumice-panel-peek
    "L" #'pumice-panel-link-mention
    (kbd "TAB") #'pumice-panel-next
    (kbd "<backtab>") #'pumice-panel-previous
    (kbd "C-j") #'pumice-panel-next
    (kbd "C-k") #'pumice-panel-previous
    "gr" #'pumice-panel-refresh
    "q" #'pumice-panel-toggle)

  ;; h and l step out of and into folders, as in ranger.
  (evil-set-initial-state 'pumice-tree-mode 'motion)
  (evil-define-key* 'motion pumice-tree-mode-map
    (kbd "RET") #'pumice-tree-visit
    "l" #'pumice-tree-expand
    "h" #'pumice-tree-collapse
    "o" #'pumice-tree-peek
    (kbd "TAB") #'pumice-tree-toggle
    "za" #'pumice-tree-toggle
    "zM" #'pumice-tree-collapse-all
    "zR" #'pumice-tree-expand-all
    "s" #'pumice-tree-sort
    "a" #'pumice-tree-new-note
    "r" #'pumice-tree-rename
    "gr" #'pumice-tree-refresh
    "q" #'pumice-tree-quit))

(with-eval-after-load 'evil
  (pumice-evil--bind))

(provide 'pumice-evil)
;;; pumice-evil.el ends here
