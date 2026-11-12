;;; pumice-commands.el --- Navigating and creating notes -*- lexical-binding: t; -*-

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

;; The interactive side of pumice.el: the note switcher, following and
;; inserting links, daily notes, templates, capture, search and tags.

;;; Code:

(require 'pumice-core)

(declare-function consult--read "consult")
(declare-function consult--file-preview "consult")
(declare-function consult-ripgrep "consult")
(declare-function evil-set-jump "evil-jumps")
(declare-function org-read-date "org")
(declare-function w32-shell-execute "w32fns.c")

(defcustom pumice-log-heading "Log"
  "Heading in the daily note under which `pumice-log' files its entries."
  :type 'string :group 'pumice)

(defcustom pumice-home-note "Home"
  "Name of the note `pumice-home' opens."
  :type 'string :group 'pumice)

(defcustom pumice-file-extensions
  '("png" "jpg" "jpeg" "gif" "svg" "webp" "pdf" "base" "canvas" "csv"
    "mp3" "mp4" "mov" "wav")
  "Extensions that mark a link target as a file, not a note to create."
  :type '(repeat string) :group 'pumice)

(defvar pumice--history nil "Minibuffer history for note names.")

;;; Opening notes

(defun pumice--now ()
  "Return the current time.  A function so that tests can pin the clock."
  (current-time))

(defun pumice--file-buffer (path)
  "Return a buffer visiting PATH.
Emacs opens a file read-only when its folder is missing.  A new note is
made writable instead, and its folder is created by the first save."
  ;; Asking `find-file-noselect' again for a new note in a missing folder
  ;; makes it offer to turn the buffer read-only, so reuse the buffer.
  (let ((buffer (or (find-buffer-visiting path) (find-file-noselect path))))
    (unless (file-exists-p path)
      (with-current-buffer buffer
        (setq buffer-read-only nil)
        (add-hook 'before-save-hook #'pumice-ensure-directory nil t)))
    buffer))

(defun pumice-ensure-directory ()
  "Create the directory of the current buffer's file if it is missing.
New notes are plain unsaved buffers, so their folder may not exist until
the first save."
  (when buffer-file-name
    (make-directory (file-name-directory buffer-file-name) t)))

(defun pumice--new-note-directory (vault)
  "Return the directory in which VAULT creates new notes."
  (cond ((pumice-setting vault :new-note-folder)
         (expand-file-name (pumice-setting vault :new-note-folder)
                           (pumice--root vault)))
        ((and (pumice-setting vault :new-note-current) buffer-file-name
              (equal (pumice-root-for buffer-file-name) (pumice--root vault)))
         (file-name-directory buffer-file-name))
        (t (pumice--root vault))))

(defun pumice--new-note-path (vault name)
  "Return the path VAULT gives a new note called NAME.
A NAME with a folder in it is taken relative to the vault root."
  (let ((name (string-remove-suffix ".md" (string-trim name))))
    (concat (if (string-search "/" name)
                (expand-file-name name (pumice--root vault))
              (expand-file-name name (pumice--new-note-directory vault)))
            ".md")))

(defun pumice--goto-heading (heading)
  "Move to HEADING, or to the block with id HEADING if it starts with ^."
  (when (and heading (not (string-empty-p heading)))
    (let ((case-fold-search t)
          (regexp (if (string-prefix-p "^" heading)
                      (concat (regexp-quote heading) "[ \t]*$")
                    (concat "^#+[ \t]+" (regexp-quote (string-trim heading))
                            "[ \t]*$")))
          (start (point)))
      (goto-char (point-min))
      (if (re-search-forward regexp nil t)
          (beginning-of-line)
        (goto-char start)))))

(defun pumice--visit (path &optional heading other-window)
  "Visit PATH, remembering where we came from, then go to HEADING.
Use the OTHER-WINDOW if that is non-nil."
  (when (fboundp 'evil-set-jump) (evil-set-jump))
  (let ((buffer (pumice--file-buffer path)))
    (if other-window
        (switch-to-buffer-other-window buffer)
      (pop-to-buffer-same-window buffer)))
  (pumice--goto-heading heading))

(defun pumice-open (vault target &optional heading from other-window)
  "Open what link TARGET means in VAULT: a note, a file, or a new note.
HEADING is a heading or ^block to land on and FROM the note holding the link."
  (if-let* ((note (pumice-resolve vault target from)))
      (pumice--visit (pumice-note-path note) heading other-window)
    (if-let* ((file (pumice-resolve-file vault target)))
        (pumice--visit file nil other-window)
      (when (member (downcase (or (file-name-extension target) ""))
                    pumice-file-extensions)
        (user-error "No file called %s in this vault" target))
      (pumice--visit (pumice--new-note-path vault target) nil other-window)
      (message "New note: %s (save to create it)" target))))

;;; Choosing a note

(defun pumice--candidates (vault notes)
  "Return an alist of display string to (NOTE . ALIAS) for NOTES in VAULT.
Notes that share a name are told apart by folder.  Each alias is offered
as a candidate of its own."
  (let (result)
    (dolist (note notes)
      (let* ((name (pumice-note-name note))
             (dup (cdr (gethash (downcase name) (pumice--names vault)))))
        (push (cons (if dup
                        (format "%s  (%s)" name
                                (directory-file-name
                                 (or (file-name-directory (pumice-note-rel note))
                                     "/")))
                      name)
                    (cons note nil))
              result)
        (dolist (alias (pumice-note-aliases note))
          (push (cons (format "%s  → %s" alias name) (cons note alias))
                result))))
    (nreverse result)))

(defun pumice--annotate (candidates)
  "Return a function annotating CANDIDATES with folder, tags and age."
  (lambda (cand)
    (when-let* ((note (cadr (assoc cand candidates))))
      (concat
       (propertize " " 'display '(space :align-to 52))
       (propertize (format "%-28s"
                           (truncate-string-to-width
                            (or (file-name-directory (pumice-note-rel note)) "")
                            28 nil nil t))
                   'face 'completions-annotations)
       (propertize (format "%-10s" (format-time-string
                                    "%b %e %Y" (pumice-note-mtime note)))
                   'face 'shadow)
       (propertize (mapconcat (lambda (tag) (concat " #" tag))
                              (pumice-note-tags note))
                   'face 'font-lock-keyword-face)))))

(defun pumice--main-window ()
  "Return the window notes are read and previewed in.
That is the selected window, unless it is a side window such as the
folder tree, when it is the ordinary window used last."
  (or (and (window-parameter nil 'window-side) (get-mru-window nil nil t))
      (selected-window)))

(defun pumice-read-note (prompt vault &optional notes require-match)
  "Read a note from VAULT with PROMPT, previewing candidates as they change.
NOTES narrows the choice.  Return (NOTE . ALIAS) for an existing note, with
ALIAS non-nil if it was picked by alias, or the typed string for a new one."
  (let* ((candidates (pumice--candidates vault (or notes (pumice-notes vault))))
         (lookup (lambda (selected &rest _)
                   (or (cdr (assoc selected candidates)) selected))))
    ;; The preview takes over the window the read started in, which should
    ;; not be the tree or the panel.
    (with-selected-window (pumice--main-window)
      (if (require 'consult nil t)
          (let ((preview (consult--file-preview)))
            (consult--read
             candidates
             :prompt prompt :sort nil :require-match require-match
             :category 'pumice-note :history 'pumice--history
             :annotate (pumice--annotate candidates)
             :lookup lookup
             :state (lambda (action cand)
                      (funcall preview action
                               (and (consp cand)
                                    (pumice-note-path (car cand)))))))
        (let ((completion-extra-properties
               (list :annotation-function (pumice--annotate candidates))))
          (funcall lookup (completing-read prompt candidates nil require-match
                                           nil 'pumice--history)))))))

;;;###autoload
(defun pumice-find (&optional other-window)
  "Jump to a note, or create one if the name typed matches nothing.
With a prefix argument, open it in the OTHER-WINDOW."
  (interactive "P")
  (pumice--find (pumice-current-vault) other-window))

(defun pumice--find (vault &optional other-window)
  "Read a note in VAULT and visit it, in the OTHER-WINDOW if non-nil."
  (let ((choice (pumice-read-note "Note: " vault)))
    (if (consp choice)
        (pumice--visit (pumice-note-path (car choice)) nil other-window)
      (pumice-open vault choice nil nil other-window))))

;;;###autoload
(defun pumice-home ()
  "Open the vault's home note."
  (interactive)
  (pumice-open (pumice-current-vault) pumice-home-note))

;;;###autoload
(defun pumice-random ()
  "Open a note picked at random."
  (interactive)
  (pumice--visit (pumice-note-path (seq-random-elt
                                    (pumice-notes (pumice-current-vault))))))

;;;###autoload
(defun pumice-switch-vault ()
  "Make another vault the default and pick a note in it."
  (interactive)
  (let* ((roots (mapcar (lambda (root)
                          (cons (file-name-nondirectory
                                 (directory-file-name root))
                                root))
                        (pumice-vault-roots)))
         (name (completing-read "Vault: " roots nil t)))
    (setq pumice-default-root (cdr (assoc name roots)))
    (pumice--find (pumice-vault-at pumice-default-root))))

;;; Links

(defun pumice-link-at-point ()
  "Return (LINK BEG END) for the link around point, or nil."
  (save-excursion
    (let ((pos (point)) (eol (pos-eol)) found)
      (goto-char (pos-bol))
      (while (and (not found) (re-search-forward pumice--link-regexp eol t))
        (when (and (<= (match-beginning 0) pos) (< pos (match-end 0)))
          (when-let* ((link (pumice--match-link)))
            (setq found (list link (match-beginning 0) (match-end 0))))))
      found)))

(defun pumice-toggle-checkbox ()
  "Tick or untick the task on the current line.  Return non-nil if it had one."
  (interactive)
  (save-excursion
    (goto-char (pos-bol))
    (when (looking-at "[ \t]*\\(?:[-*+]\\|[0-9]+[.)]\\)[ \t]+\\[\\(.\\)\\]")
      (replace-match (if (equal (match-string 1) " ") "x" " ") t t nil 1)
      t)))

;;;###autoload
(defun pumice-follow (&optional other-window)
  "Follow the link at point, or tick the checkbox on this line.
A link to a note that does not exist yet starts that note.  Return nil if
there was nothing here to act on.  With a prefix argument, use the
OTHER-WINDOW."
  (interactive "P")
  (let ((vault (pumice-current-vault)))
    (cond
     ((when-let* ((found (pumice-link-at-point))
                  (link (car found)))
        (pumice-open vault (pumice-link-target link) (pumice-link-heading link)
                     (pumice-note-at vault buffer-file-name) other-window)
        t))
     ((pumice-toggle-checkbox))
     ((when-let* ((url (thing-at-point 'url)))
        (browse-url url)
        t)))))

;;;###autoload
(defun pumice-follow-other-window ()
  "Follow the link at point in another window."
  (interactive)
  (pumice-follow t))

(defun pumice--link-text (vault choice &optional alias)
  "Return wikilink text for CHOICE from `pumice-read-note', shown as ALIAS.
The link is written as VAULT would resolve it from the current note."
  (let* ((from (pumice-note-at vault buffer-file-name))
         (target (if (consp choice)
                     (pumice-link-name vault (car choice) from)
                   choice))
         (alias (or alias (and (consp choice) (cdr choice)))))
    (if (and alias (not (string-empty-p alias)) (not (equal alias target)))
        (format "[[%s|%s]]" target alias)
      (format "[[%s]]" target))))

;;;###autoload
(defun pumice-insert-link ()
  "Insert a link to a note.  An active region becomes the link's text."
  (interactive)
  (let* ((vault (pumice-current-vault))
         (region (and (use-region-p)
                      (buffer-substring-no-properties
                       (region-beginning) (region-end))))
         (choice (pumice-read-note "Link to: " vault)))
    (when region (delete-region (region-beginning) (region-end)))
    (insert (pumice--link-text vault choice region))))

(defun pumice--next-link (count)
  "Move to the COUNTth link after point, or before it if COUNT is negative."
  (let ((start (point)))
    (if (> count 0)
        (progn (when-let* ((here (pumice-link-at-point)))
                 (goto-char (nth 2 here)))
               (if (re-search-forward pumice--link-regexp nil t count)
                   (goto-char (match-beginning 0))
                 (goto-char start)
                 (user-error "No more links")))
      (unless (re-search-backward pumice--link-regexp nil t (- count))
        (user-error "No more links")))))

(defun pumice-next-link (&optional count)
  "Move to the next link, or the COUNTth."
  (interactive "p")
  (pumice--next-link (or count 1)))

(defun pumice-previous-link (&optional count)
  "Move to the previous link, or the COUNTth."
  (interactive "p")
  (pumice--next-link (- (or count 1))))

;;; Templates

(defun pumice--expand-template (text title time)
  "Fill Obsidian's {{title}}, {{date}} and {{time}} variables in TEXT.
TITLE is the note's name and TIME the moment the dates are taken from."
  (replace-regexp-in-string
   "{{\\(title\\|date\\|time\\)\\(?::\\([^}]*\\)\\)?}}"
   (lambda (match)
     (let ((kind (match-string 1 match))
           (format (match-string 2 match)))
       (pcase kind
         ("title" title)
         ("date" (pumice-format-date (or format "YYYY-MM-DD") time))
         ("time" (pumice-format-date (or format "HH:mm") time)))))
   text t t))

(defun pumice--template-text (vault name title time)
  "Return template NAME from VAULT expanded for TITLE and TIME, or nil."
  (when-let* ((note (and name (pumice-resolve vault name))))
    (with-temp-buffer
      (insert-file-contents (pumice-note-path note))
      (pumice--expand-template (buffer-string) title time))))

;;;###autoload
(defun pumice-insert-template ()
  "Insert one of the vault's templates at point."
  (interactive)
  (let* ((vault (pumice-current-vault))
         (folder (or (pumice-setting vault :template-folder)
                     (user-error "This vault has no template folder")))
         (prefix (downcase (file-name-as-directory folder)))
         (templates (cl-remove-if-not
                     (lambda (note)
                       (string-prefix-p prefix (downcase (pumice-note-rel note))))
                     (pumice-notes vault)))
         (choice (pumice-read-note "Template: " vault templates t)))
    (insert (pumice--template-text
             vault (pumice-note-rel (car choice))
             (if buffer-file-name (file-name-base buffer-file-name) "")
             (pumice--now)))))

;;; Daily notes

(defun pumice--daily-buffer (vault time)
  "Return a buffer on VAULT's daily note for TIME, filled in if it is new."
  (let* ((path (pumice-daily-path vault time))
         (buffer (pumice--file-buffer path)))
    (with-current-buffer buffer
      (when (and (not (file-exists-p path)) (zerop (buffer-size)))
        (when-let* ((text (pumice--template-text
                           vault (pumice-setting vault :daily-template)
                           (file-name-base path) time)))
          (insert text)
          (goto-char (point-min)))))
    buffer))

;;;###autoload
(defun pumice-daily (&optional time)
  "Open the daily note for TIME, today by default."
  (interactive)
  (when (fboundp 'evil-set-jump) (evil-set-jump))
  (switch-to-buffer (pumice--daily-buffer (pumice-current-vault)
                                          (or time (pumice--now)))))

(defun pumice--days-from-now (days)
  "Return the time DAYS days from now."
  (time-add (pumice--now) (days-to-time days)))

;;;###autoload
(defun pumice-daily-yesterday ()
  "Open yesterday's daily note."
  (interactive)
  (pumice-daily (pumice--days-from-now -1)))

;;;###autoload
(defun pumice-daily-tomorrow ()
  "Open tomorrow's daily note."
  (interactive)
  (pumice-daily (pumice--days-from-now 1)))

;;;###autoload
(defun pumice-daily-date ()
  "Open the daily note for a date picked from the calendar."
  (interactive)
  (require 'org)
  (pumice-daily (org-read-date nil t nil "Daily note for: ")))

(defun pumice--daily-notes (vault)
  "Return (TIME . PATH) for VAULT's existing daily notes, oldest first.
Looks fifteen years back and one ahead."
  (cl-loop for offset from (* -15 366) to 366
           for time = (pumice--days-from-now offset)
           for path = (pumice-daily-path vault time)
           when (gethash path (pumice--notes vault))
           collect (cons time path)))

(defun pumice--daily-step (direction)
  "Open the nearest daily note after this one, or before if DIRECTION is -1."
  (let* ((vault (pumice-current-vault))
         (dailies (pumice--daily-notes vault))
         (here (or (car (rassoc buffer-file-name dailies)) (pumice--now)))
         (later (lambda (entry) (time-less-p here (car entry))))
         (earlier (lambda (entry) (time-less-p (car entry) here)))
         (hit (if (> direction 0)
                  (cl-find-if later dailies)
                (cl-find-if earlier dailies :from-end t))))
    (if hit
        (pumice--visit (cdr hit))
      (user-error "No %s daily note" (if (> direction 0) "later" "earlier")))))

;;;###autoload
(defun pumice-daily-next ()
  "Open the next daily note that exists."
  (interactive)
  (pumice--daily-step 1))

;;;###autoload
(defun pumice-daily-previous ()
  "Open the previous daily note that exists."
  (interactive)
  (pumice--daily-step -1))

;;; Capture

;;;###autoload
(defun pumice-capture (title)
  "Start a new note called TITLE where the vault keeps new notes."
  (interactive "sNew note: ")
  (let ((vault (pumice-current-vault)))
    (when (string-empty-p (string-trim title))
      (user-error "A note needs a name"))
    (pumice--visit (pumice--new-note-path vault title))))

(defun pumice--insert-log-entry (text time)
  "File TEXT, stamped with TIME, under the log heading of the current buffer.
The entry goes at the end of that section, or at the end of the note if
it has no such heading."
  (let ((entry (format "- %s %s" (format-time-string "%H:%M" time) text)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (if (re-search-forward
             (format "^#+[ \t]+%s[ \t]*$" (regexp-quote pumice-log-heading))
             nil t)
            (progn
              (forward-line 1)
              (if (re-search-forward "^#+[ \t]" nil t)
                  (goto-char (match-beginning 0))
                (goto-char (point-max)))
              (skip-chars-backward " \t\n")
              ;; An empty section gets a blank line under its heading.
              (insert (if (save-excursion (goto-char (pos-bol))
                                          (looking-at-p "#+[ \t]"))
                          "\n\n"
                        "\n")
                      entry)
              (unless (looking-at-p "\n\n\\|\n?\\'") (insert "\n")))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert entry "\n"))))))

;;;###autoload
(defun pumice-log (text)
  "File TEXT, with the time, under the log heading of today's daily note.
The note is saved and stays in the background."
  (interactive "sLog: ")
  (let* ((vault (pumice-current-vault))
         (now (pumice--now))
         (buffer (pumice--daily-buffer vault now)))
    (with-current-buffer buffer
      (pumice--insert-log-entry text now)
      (pumice-ensure-directory)
      (let ((save-silently t)) (save-buffer)))
    (message "Logged to %s" (file-name-base (buffer-file-name buffer)))))

;;; Search and tags

;;;###autoload
(defun pumice-search (&optional initial)
  "Search the text of every note, starting from INITIAL."
  (interactive)
  (consult-ripgrep (pumice--root (pumice-current-vault)) initial))

(defun pumice-tags (vault &optional notes)
  "Return an alist of tag to the notes in VAULT carrying it.
A nested tag such as a/b also counts towards a.  NOTES, if given, are the
only notes looked at."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (note (or notes (pumice-notes vault)))
      (dolist (tag (pumice-note-tags note))
        (let ((parts (split-string tag "/" t)) prefix)
          (dolist (part parts)
            (setq prefix (if prefix (concat prefix "/" part) part))
            (cl-pushnew note (gethash prefix table))))))
    (sort (cl-loop for tag being the hash-keys of table using (hash-values notes)
                   collect (cons tag (nreverse notes)))
          (lambda (a b) (string< (car a) (car b))))))

;;;###autoload
(defun pumice-find-by-tag ()
  "Pick a tag, then one of the notes carrying it."
  (interactive)
  (let* ((vault (pumice-current-vault))
         (tags (or (pumice-tags vault) (user-error "No tags in this vault")))
         (completion-extra-properties
          (list :annotation-function
                (lambda (tag) (format "  %d" (length (cdr (assoc tag tags)))))))
         (tag (completing-read "Tag: " tags nil t))
         (choice (pumice-read-note (format "#%s: " tag) vault
                                   (cdr (assoc tag tags)) t)))
    (pumice--visit (pumice-note-path (car choice)))))

(defun pumice--open-with-system (uri)
  "Hand URI to the system, which knows which application it belongs to.
`browse-url' would give it to a web browser."
  (pcase system-type
    ('darwin (call-process "open" nil 0 nil uri))
    ((or 'windows-nt 'cygwin) (w32-shell-execute "open" uri))
    (_ (call-process "xdg-open" nil 0 nil uri))))

;;;###autoload
(defun pumice-open-in-obsidian ()
  "Open the current note in the Obsidian app."
  (interactive)
  (unless buffer-file-name (user-error "This buffer has no file"))
  (pumice--open-with-system
   (concat "obsidian://open?path=" (url-hexify-string buffer-file-name))))

(provide 'pumice-commands)
;;; pumice-commands.el ends here
