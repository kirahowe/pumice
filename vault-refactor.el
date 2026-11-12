;;; vault-refactor.el --- Renaming and splitting notes -*- lexical-binding: t; -*-

;;; Commentary:

;; The commands that rewrite files other than the one being edited:
;; renaming or moving a note with every link to it kept working, and
;; extracting a region into a note of its own.

;;; Code:

(require 'vault)
(require 'vault-commands)

(defun vault--map-links (fn)
  "Call FN on each link in the buffer that is outside a code fence.
The match data describes the link when FN runs, as `vault--link-regexp'
left it."
  (let ((in-fence nil) (case-fold-search nil)
        (regexp (concat "^[ \t]*\\(?1:```\\|~~~\\)\\|" vault--link-regexp)))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (cond ((match-beginning 1) (setq in-fence (not in-fence)) (end-of-line))
            (in-fence (end-of-line))
            (t (let ((data (match-data)))
                 (when-let* ((link (vault--match-link)))
                   (set-match-data data)
                   (funcall fn link))))))))

(defun vault--edit-file (path fn)
  "Run FN on the text of PATH and write back whatever it changed.
A buffer already visiting PATH is edited in place and saved, unless it had
unsaved changes of its own, in which case it is left modified.  A file
nobody is visiting is rewritten without being opened."
  (if-let* ((buffer (find-buffer-visiting path)))
      (with-current-buffer buffer
        (let ((dirty (buffer-modified-p)))
          (save-excursion (save-restriction (widen) (funcall fn)))
          (when (and (not dirty) (buffer-modified-p))
            (let ((save-silently t)) (save-buffer)))))
    (with-temp-buffer
      (insert-file-contents path)
      (let ((coding last-coding-system-used))
        (set-buffer-modified-p nil)
        (funcall fn)
        (when (buffer-modified-p)
          (let ((coding-system-for-write coding))
            (write-region nil nil path nil 'silent)))))))

(defun vault-rename-note (vault note new-rel)
  "Move NOTE in VAULT to NEW-REL and repoint every link at it.
NEW-REL is a path relative to the vault root, without extension.  A link
written as a bare name stays a bare name when the new name is unambiguous;
a link written as a path gets the new path.  Return the number of links
rewritten."
  (let* ((root (vault--root vault))
         (old-path (vault-note-path note))
         (new-rel (string-remove-suffix ".md" (string-trim new-rel)))
         (new-path (concat (expand-file-name new-rel root) ".md"))
         (new-name (file-name-base new-path))
         (clash (remq note (gethash (downcase new-name) (vault--names vault))))
         (sources (delete-dups (mapcar #'car (vault-backlinks vault note))))
         (count 0))
    (when (and (file-exists-p new-path)
               ;; On a case-insensitive disk a change of case "exists".
               (not (string= (downcase new-path) (downcase old-path))))
      (user-error "%s already exists" new-rel))
    (dolist (source sources)
      (vault--edit-file
       (vault-note-path source)
       (lambda ()
         (vault--map-links
          (lambda (link)
            (let* ((wikilink (match-beginning 3))
                   (replacement
                    (save-match-data
                      (cond
                       ((not (eq note (vault-resolve
                                       vault (vault-link-target link) source)))
                        nil)
                       ((not wikilink)
                        (string-replace
                         " " "%20"
                         (file-relative-name
                          new-path
                          ;; A note linking to itself moves with the link.
                          (file-name-directory
                           (if (eq source note)
                               new-path
                             (vault-note-path source))))))
                       ((or clash (string-search "/" (vault-link-target link)))
                        new-rel)
                       (t new-name)))))
              (when replacement
                (cl-incf count)
                (replace-match replacement t t nil (if wikilink 3 7)))))))))
    (make-directory (file-name-directory new-path) t)
    (rename-file old-path new-path)
    (when-let* ((buffer (find-buffer-visiting old-path)))
      (with-current-buffer buffer
        (set-visited-file-name new-path t t)))
    (vault-refresh vault t)
    count))

;;;###autoload
(defun vault-rename (new-rel)
  "Rename or move the current note to NEW-REL, updating links to it.
NEW-REL is relative to the vault root, so editing the folder part moves
the note."
  (interactive
   (let* ((vault (vault-current))
          (note (or (vault-note-at vault buffer-file-name)
                    (user-error "Save this note before renaming it"))))
     (list (read-string "Rename to: " (vault-note-rel note)))))
  (let* ((vault (vault-current))
         (note (vault-note-at vault buffer-file-name)))
    (if (equal new-rel (vault-note-rel note))
        (message "Name unchanged")
      (let ((count (vault-rename-note vault note new-rel)))
        (message "Renamed to %s, %d link%s updated"
                 new-rel count (if (= count 1) "" "s"))))))

;;;###autoload
(defun vault-extract (title beg end)
  "Move the text between BEG and END into a new note called TITLE.
A link to the new note takes its place."
  (interactive "sExtract to new note: \nr")
  (let* ((vault (vault-current))
         (path (vault--new-note-path vault title))
         (text (string-trim (buffer-substring-no-properties beg end))))
    (when (file-exists-p path)
      (user-error "%s already exists" title))
    (make-directory (file-name-directory path) t)
    (write-region (concat text "\n") nil path nil 'silent)
    (delete-region beg end)
    (insert (format "[[%s]]" (string-remove-suffix ".md" (string-trim title))))
    (vault-refresh vault t)))

(defun vault-trash-note (vault note)
  "Move NOTE to VAULT's .trash folder, as Obsidian does.
A note of the same name already in the trash is kept: the new arrival
gets a number after its name.  Return the path it ends up at."
  (let* ((trash (expand-file-name ".trash/" (vault--root vault)))
         (name (vault-note-name note))
         (dest (expand-file-name (concat name ".md") trash))
         (n 1))
    (while (file-exists-p dest)
      (setq dest (expand-file-name (format "%s %d.md" name (cl-incf n)) trash)))
    (make-directory trash t)
    (rename-file (vault-note-path note) dest)
    (vault-refresh vault t)
    dest))

;;;###autoload
(defun vault-trash ()
  "Move the current note to the vault's .trash folder, as Obsidian does."
  (interactive)
  (let* ((vault (vault-current))
         (note (or (vault-note-at vault buffer-file-name)
                   (user-error "This buffer is not a saved note")))
         (links (length (vault-backlinks vault note))))
    (when (yes-or-no-p
           (format "Move %s to the vault trash%s? " (vault-note-name note)
                   (if (zerop links) ""
                     (format " (%d link%s will dangle)" links
                             (if (= links 1) "" "s")))))
      (vault-trash-note vault note)
      (set-buffer-modified-p nil)
      (kill-buffer))))

(provide 'vault-refactor)
;;; vault-refactor.el ends here
