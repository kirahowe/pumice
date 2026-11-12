;;; pumice-ui.el --- Note buffers and the backlinks panel -*- lexical-binding: t; -*-

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

;; `pumice-mode' is a minor mode for note buffers: it colours wikilinks by
;; whether they resolve, completes note names, headings and tags, and keeps
;; the index current as notes are saved.  `pumice-panel-toggle' shows a side
;; window that follows the current note with its backlinks, the places
;; that mention it without linking, and its outgoing links.

;;; Code:

(require 'pumice-core)
(require 'pumice-commands)
(require 'pumice-refactor)

(declare-function markdown-code-block-at-pos "markdown-mode")

(defface pumice-link '((t :inherit link :underline nil))
  "A link to a note or file that exists." :group 'pumice)
(defface pumice-link-unresolved '((t :inherit shadow :underline t))
  "A link to a note that has not been written yet." :group 'pumice)
(defface pumice-markup '((t :inherit shadow))
  "Link brackets, and the target of a link that shows other text."
  :group 'pumice)
(defface pumice-tag '((t :inherit font-lock-constant-face))
  "A #tag." :group 'pumice)
(defface pumice-panel-heading '((t :inherit bold :height 1.0))
  "Section titles in the backlinks panel." :group 'pumice)

;;; Highlighting

(defvar-keymap pumice-link-map
  :doc "Keys active on a link."
  "<mouse-2>" #'pumice-follow-mouse
  "<follow-link>" 'mouse-face)

(defun pumice-follow-mouse (event)
  "Follow the link clicked on in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (pumice-follow))

(defconst pumice--wikilink-regexp
  "\\(!?\\[\\[\\)\\([^]\n|]*\\)\\(?:\\(|\\)\\([^]\n]*\\)\\)?\\(\\]\\]\\)"
  "A wikilink split for highlighting: open, target, bar, alias, close.")

(defun pumice--in-code-p (pos)
  "Non-nil if POS is inside a Markdown code block."
  (and (derived-mode-p 'markdown-mode)
       (fboundp 'markdown-code-block-at-pos)
       (save-match-data (markdown-code-block-at-pos pos))))

(defun pumice--match-outside-code (regexp limit)
  "Search for REGEXP up to LIMIT, skipping matches inside code blocks."
  (let (found)
    (while (and (not found) (re-search-forward regexp limit t))
      (unless (pumice--in-code-p (match-beginning 0))
        (setq found t)))
    found))

(defun pumice--link-props ()
  "Return text properties for the wikilink just matched."
  (let* ((text (match-string-no-properties 2))
         (resolved
          (save-match-data
            (let ((vault (pumice-current-vault t))
                  (target (car (split-string text "#"))))
              (or (pumice-resolve vault target
                                  (pumice-note-at vault buffer-file-name))
                  (pumice-resolve-file vault target))))))
    (list 'face (if resolved 'pumice-link 'pumice-link-unresolved)
          'mouse-face 'highlight 'keymap pumice-link-map
          'help-echo "mouse-1 or C-c C-o: follow this link")))

(defconst pumice--font-lock-keywords
  `((,(lambda (limit) (pumice--match-outside-code pumice--wikilink-regexp limit))
     (1 'pumice-markup t)
     (2 (if (match-beginning 3) 'pumice-markup (pumice--link-props)) t)
     (3 'pumice-markup t t)
     (4 (pumice--link-props) t t)
     (5 'pumice-markup t))
    (,(lambda (limit)
        (pumice--match-outside-code
         "\\(?:^\\|[ \t(]\\)\\(#[[:alpha:]_][[:alnum:]_/-]*\\)" limit))
     (1 'pumice-tag t))
    ("%%.*?%%" (0 'font-lock-comment-face t)))
  "Highlighting for wikilinks, tags and Obsidian %% comments %%.")

;;; Completion

(defun pumice-note-headings (note)
  "Return the headings in NOTE, in order."
  (with-temp-buffer
    (insert-file-contents (pumice-note-path note))
    (cl-loop while (re-search-forward "^#+[ \t]+\\(.*?\\)[ \t]*$" nil t)
             collect (match-string-no-properties 1))))

(defun pumice--link-candidates (vault from)
  "Return link targets for every note in VAULT as seen from note FROM.
An alias is offered as Target|Alias, ready to insert."
  (cl-loop for note in (pumice-notes vault)
           for target = (pumice-link-name vault note from)
           collect (propertize target 'pumice-note note)
           append (mapcar (lambda (alias)
                            (propertize (concat target "|" alias)
                                        'pumice-note note))
                          (pumice-note-aliases note))))

(defun pumice--unsorted-table (candidates)
  "Return a completion table over CANDIDATES that keeps their order.
Notes arrive most recently edited first, which is the order wanted."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun pumice-completion-at-point ()
  "Complete a note name after [[, a heading after [[Note#, or a #tag.
Each asks corfu and company to pop up at once, however short the text
typed so far, so that the notes are offered as soon as [[ is typed."
  (let* ((bol (pos-bol))
         (vault (pumice-current-vault t))
         (from (pumice-note-at vault buffer-file-name)))
    (cond
     ((looking-back "\\[\\[\\([^]\n|#]*\\)\\(?:#\\([^]\n|]*\\)\\)?" bol)
      (let ((close (lambda (_ status)
                     (when (and (eq status 'finished) (not (looking-at-p "\\]\\]")))
                       (insert "]]")))))
        (if (match-beginning 2)
            (when-let* ((note (pumice-resolve vault (match-string 1) from)))
              (list (match-beginning 2) (point) (pumice-note-headings note)
                    :exclusive 'no :exit-function close
                    :company-prefix-length t))
          (list (match-beginning 1) (point)
                (pumice--unsorted-table (pumice--link-candidates vault from))
                :exclusive 'no :exit-function close
                :company-prefix-length t
                :annotation-function
                (lambda (cand)
                  (when-let* ((note (get-text-property 0 'pumice-note cand))
                              (dir (file-name-directory (pumice-note-rel note))))
                    (unless (string-search "/" cand)
                      (concat "  " dir))))))))
     ((looking-back "\\(?:^\\|[ \t(]\\)#\\([[:alpha:]_][[:alnum:]_/-]*\\)" bol)
      (list (match-beginning 1) (point) (mapcar #'car (pumice-tags vault))
            :exclusive 'no :company-prefix-length t)))))

;;; The minor mode

(defun pumice--after-save ()
  "Reindex after a save so links and the panel reflect it at once."
  (pumice-refresh (pumice-current-vault t) t)
  (font-lock-flush))

(defvar-keymap pumice-mode-map
  :doc "Keys for note buffers.
\\`C-c C-o' follows a link to a note.  Anywhere else it is left to the
major mode, which in a Markdown buffer follows the other kinds of link.
The rest of the commands are in `pumice-command-map'."
  "C-c C-o" `(menu-item "" pumice-follow-link
                        :filter ,(lambda (command)
                                   (and (save-match-data (pumice-link-at-point))
                                        command))))

;;;###autoload
(define-minor-mode pumice-mode
  "Minor mode for a note that lives in a vault."
  :lighter " Pumice"
  (if pumice-mode
      (progn
        ;; Highlighting and completion read the index without scanning,
        ;; so the first note opened has to bring it up to date.
        (when-let* ((root (pumice-root-for buffer-file-name)))
          (pumice-vault-at root))
        (font-lock-add-keywords nil pumice--font-lock-keywords 'append)
        (make-local-variable 'font-lock-extra-managed-props)
        (dolist (prop '(mouse-face keymap help-echo))
          (cl-pushnew prop font-lock-extra-managed-props))
        (add-hook 'completion-at-point-functions
                  #'pumice-completion-at-point nil t)
        (add-hook 'after-save-hook #'pumice--after-save nil t)
        (add-hook 'before-save-hook #'pumice-ensure-directory nil t))
    (font-lock-remove-keywords nil pumice--font-lock-keywords)
    (remove-hook 'completion-at-point-functions #'pumice-completion-at-point t)
    (remove-hook 'after-save-hook #'pumice--after-save t)
    (remove-hook 'before-save-hook #'pumice-ensure-directory t))
  (font-lock-flush))

;;;###autoload
(defun pumice-mode-maybe ()
  "Turn on `pumice-mode' if this buffer is a Markdown file in a vault."
  (when (and buffer-file-name
             (string-suffix-p ".md" buffer-file-name t)
             (pumice-root-for buffer-file-name))
    (pumice-mode 1)))

;;;###autoload
(define-minor-mode pumice-global-mode
  "Turn on `pumice-mode' in every Markdown file opened from a vault."
  :global t :group 'pumice
  (if pumice-global-mode
      (add-hook 'find-file-hook #'pumice-mode-maybe)
    (remove-hook 'find-file-hook #'pumice-mode-maybe)))

;;; Unlinked mentions

(defun pumice-unlinked-mentions (vault note)
  "Return (PATH LINE TEXT) for lines in VAULT naming NOTE without linking.
Needs ripgrep; returns nil without it."
  (let ((names (cl-remove-if (lambda (name) (< (length name) 3))
                             (cons (pumice-note-name note)
                                   (pumice-note-aliases note))))
        (case-fold-search t))
    (when (and names (executable-find "rg"))
      (let ((linked (concat "\\[\\[[^]\n]*" (regexp-opt names) "[^]\n]*\\]\\]")))
        (cl-loop
         for line in (apply #'process-lines-ignore-status
                            "rg" "--fixed-strings" "--ignore-case"
                            "--word-regexp" "--line-number" "--no-heading"
                            "--with-filename" "--color" "never"
                            "--max-count" "3" "--glob" "*.md"
                            (append (mapcan (lambda (name) (list "-e" name))
                                            names)
                                    (list (directory-file-name
                                           (pumice--root vault)))))
         when (and (string-match "\\`\\(.*?\\.md\\):\\([0-9]+\\):\\(.*\\)\\'"
                                 line)
                   (not (equal (match-string 1 line) (pumice-note-path note)))
                   (not (string-match-p linked (match-string 3 line))))
         collect (list (match-string 1 line)
                       (string-to-number (match-string 2 line))
                       (string-trim (match-string 3 line))))))))

(defun pumice-link-mention (path line note)
  "Turn the first plain mention of NOTE on LINE of PATH into a link."
  (let* ((vault (pumice-vault-at (pumice-root-for path)))
         (names (cons (pumice-note-name note) (pumice-note-aliases note)))
         (target (pumice-link-name vault note (pumice-note-at vault path)))
         (case-fold-search t) done)
    (pumice--edit-file
     path
     (lambda ()
       (goto-char (point-min))
       (forward-line (1- line))
       (when (re-search-forward (regexp-opt names 'words) (pos-eol) t)
         (let ((text (match-string 0)))
           (replace-match (if (string= text target)
                              (format "[[%s]]" target)
                            (format "[[%s|%s]]" target text))
                          t t)
           (setq done t)))))
    (pumice-refresh vault t)
    done))

;;; Side windows

;; The backlinks panel and the folder tree sit in side windows.  Anything
;; opened while one of them is selected belongs in the main window.  Left
;; alone, Emacs would split the main window for `find-file', and
;; `switch-to-buffer' would put its buffer in the narrow side window.

(define-derived-mode pumice-side-mode special-mode "Pumice"
  "Parent of the modes shown in side windows: the panel and the tree."
  (setq truncate-lines t
        cursor-in-non-selected-windows nil)
  ;; The windows are strongly dedicated.  `switch-to-buffer' called from
  ;; Lisp pops to another window when it meets one, but typed as a command
  ;; it refuses to run unless told to pop as well.
  (setq-local switch-to-buffer-in-dedicated-window 'pop))

(defun pumice--side-window-selected-p (&rest _)
  "Non-nil if the selected window shows the panel or the tree."
  (with-current-buffer (window-buffer)
    (derived-mode-p 'pumice-side-mode)))

(add-to-list 'display-buffer-alist
             '(pumice--side-window-selected-p
               (display-buffer-reuse-window display-buffer-use-some-window)
               (some-window . mru)))

(defun pumice--show-side-window (buffer side width)
  "Show BUFFER in a window WIDTH columns wide on SIDE of the frame."
  (display-buffer-in-side-window
   buffer
   `((side . ,side) (window-width . ,width)
     (dedicated . t) (preserve-size . (t . nil))
     (window-parameters (no-delete-other-windows . t)))))

;;; Backlinks panel

(defconst pumice-panel-buffer "*pumice-panel*" "Name of the panel buffer.")

(defcustom pumice-panel-width 44
  "Width of the backlinks panel in columns."
  :type 'integer :group 'pumice)

(defvar-local pumice-panel--shown nil "What the panel last drew: (PATH . TICK).")
(defvar pumice-panel--timer nil)

(defvar-keymap pumice-panel-mode-map
  :doc "Keys in the backlinks panel."
  "RET" #'pumice-panel-visit
  "o" #'pumice-panel-peek
  "l" #'pumice-panel-link-mention
  "TAB" #'pumice-panel-next
  "n" #'pumice-panel-next
  "<backtab>" #'pumice-panel-previous
  "p" #'pumice-panel-previous
  "g" #'pumice-panel-refresh
  "q" #'pumice-panel-toggle)

(define-derived-mode pumice-panel-mode pumice-side-mode "Pumice"
  "Backlinks, unlinked mentions and outgoing links of the current note.")

(defun pumice-panel--context (text)
  "Return context line TEXT with its links picked out."
  (let ((text (propertize (copy-sequence text) 'face 'shadow)) (start 0))
    (while (string-match "\\[\\[[^]\n]*\\]\\]" text start)
      (put-text-property (match-beginning 0) (match-end 0) 'face 'pumice-link text)
      (setq start (match-end 0)))
    text))

(defun pumice-panel--section (title groups)
  "Insert a section called TITLE.
GROUPS is a list of (LABEL ITEM FACE . LINES) where LINES are (ITEM . TEXT)
pairs shown under the label.  ITEM is what RET on that line acts on."
  (insert (propertize (format "%s  %d\n" title
                              (if (cl-some #'cdddr groups)
                                  (cl-loop for g in groups sum (length (cdddr g)))
                                (length groups)))
                      'face 'pumice-panel-heading))
  (pcase-dolist (`(,label ,item ,face . ,lines) groups)
    (insert (propertize (concat "  " label "\n") 'face face 'pumice-item item))
    (pcase-dolist (`(,line-item . ,text) lines)
      (insert (propertize (concat "    " (pumice-panel--context text) "\n")
                          'pumice-item line-item))))
  (insert "\n"))

(defun pumice-panel--group (entries)
  "Group ENTRIES, a list of (PATH LINE TEXT), into panel groups by file."
  (mapcar (lambda (group)
            (let ((path (car group)))
              `(,(file-name-base path) (:path ,path) pumice-link
                ,@(mapcar (lambda (entry)
                            (cons (list :path path :line (nth 1 entry))
                                  (nth 2 entry)))
                          (cdr group)))))
          (seq-group-by #'car entries)))

(defun pumice-panel--render (vault note)
  "Draw the panel for NOTE in VAULT."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (same (equal (car pumice-panel--shown) (pumice-note-path note))))
    (erase-buffer)
    (insert (propertize (pumice-note-name note) 'face '(:inherit bold :height 1.2))
            "\n"
            (propertize (concat (or (file-name-directory (pumice-note-rel note)) "")
                                (mapconcat (lambda (tag) (concat " #" tag))
                                           (pumice-note-tags note)))
                        'face 'shadow)
            "\n\n")
    (pumice-panel--section
     "Backlinks"
     (pumice-panel--group
      (mapcar (lambda (pair)
                (list (pumice-note-path (car pair))
                      (pumice-link-line (cdr pair)) (pumice-link-text (cdr pair))))
              (pumice-backlinks vault note))))
    (pumice-panel--section
     "Unlinked mentions"
     (mapcar (lambda (group)
               (dolist (line (cdddr group))
                 (setcar line (append (car line) (list :mention note))))
               group)
             (pumice-panel--group (pumice-unlinked-mentions vault note))))
    (pumice-panel--section
     "Links"
     (cl-loop for target in (delete-dups
                             (mapcar #'pumice-link-target (pumice-note-links note)))
              for dest = (pumice-resolve vault target note)
              for file = (and (not dest) (pumice-resolve-file vault target))
              unless (string-empty-p target)
              collect (cond (dest (list (pumice-note-name dest)
                                        (list :path (pumice-note-path dest))
                                        'pumice-link))
                            (file (list target (list :path file) 'pumice-link))
                            (t (list target (list :new target)
                                     'pumice-link-unresolved)))))
    (setq pumice-local-root (pumice--root vault)
          pumice-panel--shown (cons (pumice-note-path note) (pumice--tick vault)))
    (goto-char (point-min))
    (when same (forward-line (1- line)))))

(defun pumice-panel--sync (&optional force)
  "Point the panel at the selected window's note if that changed.
With FORCE, redraw even if nothing seems to have."
  (let ((panel (get-buffer pumice-panel-buffer)))
    (if (not (and panel (get-buffer-window panel t)))
        (when pumice-panel--timer
          (cancel-timer pumice-panel--timer)
          (setq pumice-panel--timer nil))
      (let ((path (buffer-file-name (window-buffer (selected-window)))))
        (when-let* ((root (and path (pumice-root-for path)))
                    (vault (pumice-vault-at root))
                    (note (pumice-note-at vault path)))
          (with-current-buffer panel
            (when (or force
                      (not (equal pumice-panel--shown
                                  (cons path (pumice--tick vault)))))
              (let ((window (get-buffer-window panel t)))
                (pumice-panel--render vault note)
                (set-window-point window (point))))))))))

;;;###autoload
(defun pumice-panel-toggle ()
  "Show or hide the backlinks panel beside the current note."
  (interactive)
  (if-let* ((window (get-buffer-window pumice-panel-buffer)))
      (delete-window window)
    (with-current-buffer (get-buffer-create pumice-panel-buffer)
      (unless (derived-mode-p 'pumice-panel-mode) (pumice-panel-mode))
      (pumice--show-side-window (current-buffer) 'right pumice-panel-width))
    (unless pumice-panel--timer
      (setq pumice-panel--timer
            (run-with-idle-timer 0.2 t #'pumice-panel--sync)))
    (pumice-panel--sync t)))

;;;###autoload
(defun pumice-panel-focus ()
  "Move to the backlinks panel, opening it if needed."
  (interactive)
  (unless (get-buffer-window pumice-panel-buffer) (pumice-panel-toggle))
  (select-window (get-buffer-window pumice-panel-buffer)))

(defun pumice-panel-refresh ()
  "Redraw the panel from disk."
  (interactive)
  (when pumice-local-root (pumice-refresh (pumice-vault-at pumice-local-root t) t))
  (setq pumice-panel--shown nil)
  (when-let* ((window (get-mru-window nil nil t)))
    (with-selected-window window (pumice-panel--sync t))))

(defun pumice-panel--move (direction)
  "Move to the next panel item, or the previous if DIRECTION is -1."
  (let ((pos (point)) found)
    (while (and (not found) (zerop (forward-line direction)) (not (eobp)))
      (setq found (get-text-property (point) 'pumice-item)))
    (unless found (goto-char pos))))

(defun pumice-panel-next ()
  "Move to the next item."
  (interactive)
  (pumice-panel--move 1))

(defun pumice-panel-previous ()
  "Move to the previous item."
  (interactive)
  (pumice-panel--move -1))

(defun pumice-panel--open (item root)
  "Show ITEM from the vault at ROOT in the last used ordinary window."
  (select-window (or (get-mru-window nil nil t) (next-window)))
  (if-let* ((target (plist-get item :new)))
      (pumice-open (pumice-vault-at root) target)
    (pumice--visit (plist-get item :path))
    (when-let* ((line (plist-get item :line)))
      (goto-char (point-min))
      (forward-line (1- line))
      (recenter))))

(defun pumice-panel-visit ()
  "Go to the note, or the line in it, that this panel line stands for."
  (interactive)
  (pumice-panel--open (or (get-text-property (pos-bol) 'pumice-item)
                          (user-error "Nothing to visit on this line"))
                      pumice-local-root))

(defun pumice-panel-peek ()
  "Show this panel line's note in the other window and stay in the panel."
  (interactive)
  (let ((panel (selected-window)))
    (pumice-panel-visit)
    (select-window panel)))

(defun pumice-panel-link-mention ()
  "Turn the unlinked mention on this panel line into a link."
  (interactive)
  (let* ((item (get-text-property (pos-bol) 'pumice-item))
         (note (or (plist-get item :mention)
                   (user-error "This line is not an unlinked mention"))))
    (if (pumice-link-mention (plist-get item :path) (plist-get item :line) note)
        (progn (setq pumice-panel--shown nil)
               (pumice-panel-refresh)
               (message "Linked"))
      (message "The mention is no longer on that line"))))

(provide 'pumice-ui)
;;; pumice-ui.el ends here
