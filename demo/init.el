;;; init.el --- Emacs as set up for recording the demo -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:

;; demo/record.sh starts Emacs with this file.  It shows pumice with the
;; optional packages that make it look its best: vertico, marginalia and
;; orderless for picking notes, consult for the live preview, corfu for the
;; popup after [[, markdown-mode, and a theme.  They are installed on first
;; use into demo/.elpa, or looked for in $PUMICE_DEMO_ELPA if that is set,
;; and never touch your own configuration.
;;
;; Run in batch mode, this file only installs the packages.

;;; Code:

(defconst demo-directory (file-name-directory load-file-name))

;; A recording should not wait on the native compiler, or be interrupted by
;; its warnings.
(setq native-comp-jit-compilation nil
      native-comp-enable-subr-trampolines nil)

(setq inhibit-startup-screen t
      initial-scratch-message nil
      make-backup-files nil
      create-lockfiles nil
      auto-save-default nil
      save-silently t
      ring-bell-function #'ignore
      use-short-answers t)
(fset 'display-startup-echo-area-message #'ignore)

(require 'package)
(setq package-user-dir (or (getenv "PUMICE_DEMO_ELPA")
                           (expand-file-name ".elpa" demo-directory)))
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(let ((wanted '(vertico marginalia orderless consult corfu markdown-mode
                atom-one-dark-theme)))
  (unless (seq-every-p #'package-installed-p wanted)
    (package-refresh-contents)
    (dolist (name wanted)
      (unless (package-installed-p name)
        (package-install name)))))

(unless noninteractive
  (menu-bar-mode -1)
  (load-theme 'atom-one-dark t)
  (vertico-mode 1)
  (marginalia-mode 1)
  (setq completion-styles '(orderless basic))
  (setq corfu-auto t
        corfu-auto-delay 0.15)
  (global-corfu-mode 1)
  (add-to-list 'auto-mode-alist '("\\.md\\'" . gfm-mode))

  (add-to-list 'load-path (expand-file-name ".." demo-directory))
  (require 'pumice)
  (setq pumice-vault-directories (list (getenv "PUMICE_DEMO_VAULT"))
        pumice-panel-width 38
        pumice-tree-width 24)
  (pumice-global-mode 1)
  (keymap-global-set "C-c n" 'pumice-command-map)
  (add-hook 'pumice-mode-hook #'visual-line-mode)

  ;; A bar along the top shows the last key pressed and the command it ran,
  ;; so that someone watching can tell what is being typed.
  (defvar demo-keys nil "The last key shown, as (KEYS . COMMAND).")
  (defun demo-note-keys ()
    "Remember the key just pressed, unless it only typed a character."
    (let ((keys (key-description (this-command-keys-vector))))
      (unless (or (string-empty-p keys)
                  (memq this-command '(self-insert-command
                                       delete-backward-char
                                       corfu-insert vertico-exit)))
        (setq demo-keys (cons keys this-command))
        (force-mode-line-update t))))
  (add-hook 'pre-command-hook #'demo-note-keys)
  (defun demo-bar ()
    "Return the top bar: a title on the left, the last key on the right."
    (let* ((left (propertize "  pumice " 'face '(:weight bold)))
           (right (if demo-keys
                      (concat (propertize (format " %s " (car demo-keys))
                                          'face '(:inverse-video t :weight bold))
                              (format "  %s  " (cdr demo-keys)))
                    ""))
           (pad (max 1 (- (frame-width) (string-width left)
                          (string-width right)))))
      `((demo menu-item ,(concat left (make-string pad ?\s) right) ignore))))
  (setq tab-bar-format '(demo-bar))
  (tab-bar-mode 1)
  (setq-default mode-line-format
                '(" " (:eval (propertize "%b" 'face 'bold))
                  (:eval (if (and buffer-file-name (buffer-modified-p))
                             "  •"
                           "")))))

;;; init.el ends here
