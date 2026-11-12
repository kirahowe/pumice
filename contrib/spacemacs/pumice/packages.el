;;; packages.el --- pumice layer packages for Spacemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kira Howe
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Spacemacs layer for pumice.  Copy or symlink this directory to
;; ~/.emacs.d/private/pumice and add pumice to
;; `dotspacemacs-configuration-layers'.

;;; Code:

(defconst pumice-packages
  '((pumice :location (recipe :fetcher github :repo "kirahowe/pumice")))
  "The Lisp packages the pumice layer needs.")

(defun pumice/init-pumice ()
  "Turn pumice on and put its commands under the leader key."
  (use-package pumice
    :config
    (pumice-global-mode 1)
    ;; The emacs editing style has no use for the vim keys.
    (when (memq (or (car-safe dotspacemacs-editing-style)
                    dotspacemacs-editing-style)
                '(vim hybrid))
      (require 'pumice-evil))
    (spacemacs/declare-prefix pumice-leader-key "pumice")
    (spacemacs/set-leader-keys pumice-leader-key 'pumice-command-map)))

;;; packages.el ends here
