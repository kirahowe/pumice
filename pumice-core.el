;;; pumice-core.el --- Vault discovery, the note index and links -*- lexical-binding: t; -*-

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

;; The data model: finding vaults, reading each vault's .obsidian settings,
;; the note index, link parsing and link resolution.  Commands are in
;; pumice-commands.el, and the editing mode and backlinks panel in
;; pumice-ui.el.  pumice.el loads them all and says how to set things up.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup pumice nil
  "Obsidian-compatible personal wiki."
  :group 'text
  :prefix "pumice-")

(defcustom pumice-vault-directories nil
  "Vault roots.  When nil, read them from `pumice-obsidian-registry'."
  :type '(repeat directory))

(defcustom pumice-obsidian-registry
  "~/Library/Application Support/obsidian/obsidian.json"
  "Obsidian's list of known vaults."
  :type 'file)

(defcustom pumice-refresh-interval 2
  "Seconds for which a directory scan is trusted before rescanning."
  :type 'number)

(defvar pumice-default-root nil
  "Root of the vault used when the current buffer is not inside one.")

(defvar-local pumice-local-root nil
  "Vault root of a buffer that shows a vault without visiting a file in it.
The backlinks panel and the folder tree set it, so that commands run from
them act on the vault they are showing.")

(defvar pumice--cache (make-hash-table :test 'equal)
  "Vault structs keyed by root directory.")

(cl-defstruct (pumice-vault (:constructor pumice--make-vault)
                            (:conc-name pumice--) (:copier nil))
  root settings
  (notes (make-hash-table :test 'equal)) ; absolute path -> note
  (names (make-hash-table :test 'equal)) ; downcased basename -> notes
  (rels (make-hash-table :test 'equal))  ; downcased relative path -> note
  files                                  ; relative paths of non-note files
  backlinks backlinks-tick
  (tick 0) last-scan)

(cl-defstruct (pumice-note (:constructor pumice--make-note) (:copier nil))
  path rel name aliases tags links props mtime)

(cl-defstruct (pumice-link (:constructor pumice--make-link) (:copier nil))
  target heading alias line text embed)

;;; Vault discovery

(defun pumice--read-json (file)
  "Parse FILE as JSON into alists, or return nil if that fails."
  (when (file-readable-p file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil)))))

(defun pumice--registry ()
  "Return (ROOT . OPEN) pairs from Obsidian's vault registry."
  (let ((json (pumice--read-json (expand-file-name pumice-obsidian-registry))))
    (cl-loop for (_id . entry) in (alist-get 'vaults json)
             for path = (alist-get 'path entry)
             when (and path (file-directory-p path))
             collect (cons (file-name-as-directory path)
                           (alist-get 'open entry)))))

(defvar pumice--vault-roots nil
  "Roots read from the Obsidian registry, kept so it is parsed only once.
`pumice-forget' clears it.")

(defun pumice-vault-roots ()
  "Return the root directory of every known vault."
  (if pumice-vault-directories
      (mapcar (lambda (d) (file-name-as-directory (expand-file-name d)))
              pumice-vault-directories)
    (or pumice--vault-roots
        (setq pumice--vault-roots (mapcar #'car (pumice--registry))))))

(defun pumice-forget ()
  "Drop every cached index and the list of vaults, to start from disk again."
  (interactive)
  (setq pumice--vault-roots nil)
  (clrhash pumice--cache))

(defun pumice-root-for (file)
  "Return the vault root containing FILE, or nil."
  (when file
    (let ((file (expand-file-name file)))
      (or (cl-find-if (lambda (root) (string-prefix-p root file))
                      (pumice-vault-roots))
          (when-let* ((dir (locate-dominating-file file ".obsidian")))
            (file-name-as-directory (expand-file-name dir)))))))

(defun pumice--default-root ()
  "Return the fallback vault root, choosing one on first use."
  (or pumice-default-root
      (setq pumice-default-root
            (or (and (not pumice-vault-directories)
                     (car (cl-find-if #'cdr (pumice--registry))))
                (car (pumice-vault-roots))
                (user-error "No vault found; set `pumice-vault-directories'")))))

(defun pumice-vault-at (root &optional no-refresh)
  "Return the vault rooted at ROOT.
The index is brought up to date first unless NO-REFRESH is non-nil."
  (let ((vault (or (gethash root pumice--cache)
                   (puthash root (pumice--make-vault :root root) pumice--cache))))
    (unless no-refresh (pumice-refresh vault))
    vault))

(defun pumice-current-vault (&optional no-refresh)
  "Return the vault for the current buffer, else the default vault.
The index is brought up to date first unless NO-REFRESH is non-nil."
  (pumice-vault-at (or (pumice-root-for (or buffer-file-name pumice-local-root))
                       (pumice--default-root))
                   no-refresh))

;;; Settings borrowed from .obsidian

(defun pumice--load-settings (vault)
  "Read the parts of VAULT's Obsidian configuration that matter here."
  (let* ((dir (expand-file-name ".obsidian/" (pumice--root vault)))
         (app (pumice--read-json (expand-file-name "app.json" dir)))
         (daily (pumice--read-json (expand-file-name "daily-notes.json" dir)))
         (templates (pumice--read-json (expand-file-name "templates.json" dir)))
         (nonempty (lambda (s) (and (stringp s) (not (string-empty-p s)) s))))
    (setf (pumice--settings vault)
          (list :daily-folder (funcall nonempty (alist-get 'folder daily))
                :daily-format (or (funcall nonempty (alist-get 'format daily))
                                  "YYYY-MM-DD")
                :daily-template (funcall nonempty (alist-get 'template daily))
                :template-folder (funcall nonempty (alist-get 'folder templates))
                :new-note-folder
                (and (equal (alist-get 'newFileLocation app) "folder")
                     (funcall nonempty (alist-get 'newFileFolderPath app)))
                :new-note-current
                (equal (alist-get 'newFileLocation app) "current")))))

(defun pumice-setting (vault key)
  "Return VAULT's setting KEY."
  (unless (pumice--settings vault) (pumice--load-settings vault))
  (plist-get (pumice--settings vault) key))

;;; Parsing

(defconst pumice--link-regexp
  (concat
   ;; [[target#heading|alias]], optionally an ![[embed]]
   "\\(?2:!\\)?\\[\\[\\(?3:[^]\n|#]*\\)\\(?:#\\(?4:[^]\n|]*\\)\\)?"
   "\\(?:|\\(?5:[^]\n]*\\)\\)?\\]\\]"
   ;; [text](relative/path.md#heading)
   "\\|\\[\\(?6:[^]\n]*\\)\\](\\(?7:[^)\n#]+\\.md\\)\\(?:#\\(?8:[^)\n]*\\)\\)?)")
  "Matches a wikilink (groups 2-5) or a Markdown link to a note (6-8).")

(defconst pumice--scan-regexp
  (concat "^[ \t]*\\(?1:```\\|~~~\\)"
          "\\|" pumice--link-regexp
          ;; #tag
          "\\|\\(?:^\\|[ \t(]\\)#\\(?9:[[:alpha:]_][[:alnum:]_/-]*\\)")
  "Matches code fences, wikilinks, Markdown links to notes, and tags.")

(defun pumice--match-link ()
  "Build a link from the current `pumice--link-regexp' match, or return nil."
  (cond
   ((match-beginning 3)
    (pumice--make-link :target (string-trim (match-string-no-properties 3))
                       :heading (match-string-no-properties 4)
                       :alias (match-string-no-properties 5)
                       :embed (and (match-beginning 2) t)))
   ((and (match-beginning 7)
         (not (string-match-p "\\`[a-z]+:" (match-string-no-properties 7))))
    (pumice--make-link :target (url-unhex-string (match-string-no-properties 7))
                       :heading (match-string-no-properties 8)
                       :alias (match-string-no-properties 6)))))

(defun pumice--yaml-scalar (text)
  "Return YAML scalar TEXT as a string, without its quotes."
  (let ((text (string-trim text)))
    (cond ((string-match "\\`\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\"\\'" text)
           (replace-regexp-in-string "\\\\\\(.\\)" "\\1" (match-string 1 text)))
          ((string-match "\\`'\\(\\(?:[^']\\|''\\)*\\)'\\'" text)
           (string-replace "''" "'" (match-string 1 text)))
          (t text))))

(defconst pumice--yaml-key-regexp
  "^\\([^] \t\n#:[-][^:\n]*\\):\\(?:[ \t]+\\(.*\\)\\|[ \t]*\\)$"
  "Matches a top-level frontmatter line: the key, then any inline value.")

(defun pumice--frontmatter-bounds ()
  "Return (START . END) of the buffer's frontmatter lines, or nil.
START is after the opening --- line and END is at the closing one."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "---[ \t]*\n")
      (forward-line 1)
      (let ((start (point)))
        (when (re-search-forward "^---[ \t]*$" nil t)
          (cons start (match-beginning 0)))))))

(defun pumice--frontmatter ()
  "Return the buffer's frontmatter as an alist of (KEY . VALUE).
VALUE is a string, or a list of strings for a YAML list.  This reads the
flat properties Obsidian writes, not all of YAML: a nested mapping is
skipped, and every scalar comes back as the text that was written."
  (when-let* ((bounds (pumice--frontmatter-bounds)))
    (save-excursion
      (goto-char (car bounds))
      (let (props)
        (while (< (point) (cdr bounds))
          (if (not (looking-at pumice--yaml-key-regexp))
              (forward-line 1)
            (let ((key (string-trim (match-string-no-properties 1)))
                  (inline (string-trim (or (match-string-no-properties 2) ""))))
              (forward-line 1)
              (push
               (cons key
                     (cond
                      ((string-match "\\`\\[\\(.*\\)\\]\\'" inline)
                       (cl-remove-if #'string-empty-p
                                     (mapcar #'pumice--yaml-scalar
                                             (split-string (match-string 1 inline)
                                                           ","))))
                      ((not (string-empty-p inline)) (pumice--yaml-scalar inline))
                      ((looking-at "[ \t]*-[ \t]")
                       (cl-loop while (and (< (point) (cdr bounds))
                                           (looking-at "[ \t]*-[ \t]+\\(.*\\)$"))
                                collect (pumice--yaml-scalar
                                         (match-string-no-properties 1))
                                do (forward-line 1)))
                      (t "")))
               props))))
        (nreverse props)))))

(defun pumice--prop-list (props key)
  "Return the value of KEY in the alist PROPS as a list of strings.
A scalar is split at commas, as Obsidian does for tags and aliases."
  (let ((value (cdr (assoc key props))))
    (cl-remove-if #'string-empty-p
                  (mapcar (lambda (item)
                            (string-remove-prefix "#" (string-trim item)))
                          (if (listp value) value (split-string value ","))))))

(defun pumice--yaml-quote (value)
  "Return the string VALUE as a YAML scalar, quoted only where it must be."
  (if (or (string-empty-p value)
          (string-match-p
           (concat "\\`[][{}#&*!|>'\"%@`,]\\|\\`[-?:][ \t]\\|:[ \t]\\|:\\'"
                   "\\|[ \t]#\\|\\`[ \t]\\|[ \t]\\'\\|\n")
           value))
      (concat "\""
              (string-replace
               "\n" "\\n"
               (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" value t))
              "\"")
    value))

(defun pumice-set-property (key value)
  "Set frontmatter property KEY of the note in the current buffer to VALUE.
VALUE is a string, a list of strings, or nil to remove the property.  A
note without frontmatter gets some.  Return non-nil if the text changed."
  (let ((line (cond ((null value) "")
                    ((listp value)
                     (concat key ":\n"
                             (mapconcat (lambda (item)
                                          (concat "  - " (pumice--yaml-quote item)
                                                  "\n"))
                                        value)))
                    (t (format "%s: %s\n" key (pumice--yaml-quote value)))))
        (bounds (pumice--frontmatter-bounds))
        (before (buffer-string))
        (case-fold-search nil))
    (save-excursion
      (cond
       ((null bounds)
        (when value
          (goto-char (point-min))
          (insert "---\n" line "---\n")))
       ((progn (goto-char (car bounds))
               (re-search-forward (format "^%s:\\(?:[ \t].*\\)?$" (regexp-quote key))
                                  (cdr bounds) t))
        ;; Replace the line and whatever continues it: the items of a
        ;; list, or the indented lines of a longer value.
        (let ((start (pos-bol)))
          (forward-line 1)
          (while (and (< (point) (cdr bounds))
                      (looking-at "[ \t]+[^ \t\n]\\|-[ \t]"))
            (forward-line 1))
          (delete-region start (point))
          (insert line)))
       (t (goto-char (cdr bounds))
          (insert line))))
    (not (equal before (buffer-string)))))

(defun pumice--line-text ()
  "Return the current line, trimmed and capped in length."
  (truncate-string-to-width
   (string-trim (buffer-substring-no-properties (pos-bol) (pos-eol)))
   240 nil nil t))

(defun pumice--parse-buffer ()
  "Return (ALIASES TAGS LINKS PROPS) for the note text in the current buffer."
  (let* ((props (pumice--frontmatter))
         (aliases (append (pumice--prop-list props "aliases")
                          (pumice--prop-list props "alias")))
         (tags (append (pumice--prop-list props "tags")
                       (pumice--prop-list props "tag")))
         links (in-fence nil) (case-fold-search nil))
    ;; Scan from the top again: Obsidian counts a [[link]] in a property,
    ;; such as parent: "[[Goals]]", like any other.
    (goto-char (point-min))
    (while (re-search-forward pumice--scan-regexp nil t)
      (cond
       ((match-beginning 1) (setq in-fence (not in-fence)) (end-of-line))
       (in-fence (end-of-line))
       ((or (match-beginning 3) (match-beginning 7))
        (when-let* ((link (pumice--match-link)))
          (setf (pumice-link-line link) (line-number-at-pos)
                (pumice-link-text link) (pumice--line-text))
          (push link links)))
       ((match-beginning 9)
        (cl-pushnew (match-string-no-properties 9) tags :test #'equal))))
    (list aliases (delete-dups tags) (nreverse links) props)))

(defun pumice--parse-file (path)
  "Return (ALIASES TAGS LINKS PROPS) for the note at PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (pumice--parse-buffer)))

;;; Index

(defun pumice--hidden-p (name)
  "Non-nil if file or directory NAME should stay out of the index."
  (or (string-prefix-p "." name)
      (string-suffix-p "~" name)
      (string-prefix-p "#" name)))

(defun pumice--list-files (root)
  "Return every indexable file under ROOT as an absolute path."
  (cl-remove-if
   (lambda (f) (pumice--hidden-p (file-name-nondirectory f)))
   (directory-files-recursively
    root "" nil
    (lambda (dir) (not (pumice--hidden-p (file-name-nondirectory dir)))))))

(defun pumice--rel (vault path)
  "Return PATH relative to VAULT's root, without a .md extension."
  (string-remove-suffix ".md" (file-relative-name path (pumice--root vault))))

(defun pumice-refresh (vault &optional force)
  "Bring VAULT's index up to date with the files on disk.
Scans are throttled by `pumice-refresh-interval' unless FORCE is non-nil.
Only notes whose modification time changed are parsed again."
  (when (or force
            (null (pumice--last-scan vault))
            (> (- (float-time) (pumice--last-scan vault))
               pumice-refresh-interval))
    (let ((notes (pumice--notes vault))
          (seen (make-hash-table :test 'equal))
          (changed nil) files)
      (dolist (path (pumice--list-files (pumice--root vault)))
        (if (not (string-suffix-p ".md" path))
            (push (file-relative-name path (pumice--root vault)) files)
          (puthash path t seen)
          (let ((mtime (file-attribute-modification-time
                        (file-attributes path)))
                (old (gethash path notes)))
            (unless (and old (equal mtime (pumice-note-mtime old)))
              (pcase-let ((`(,aliases ,tags ,links ,props)
                           (condition-case nil (pumice--parse-file path)
                             (error (list nil nil nil nil)))))
                (puthash path
                         (pumice--make-note
                          :path path :rel (pumice--rel vault path)
                          :name (file-name-base path)
                          :aliases aliases :tags tags :links links
                          :props props :mtime mtime)
                         notes)
                (setq changed t))))))
      (maphash (lambda (path _)
                 (unless (gethash path seen)
                   (remhash path notes)
                   (setq changed t)))
               notes)
      (unless (equal files (pumice--files vault))
        (setf (pumice--files vault) files)
        (setq changed t))
      (when changed
        (clrhash (pumice--names vault))
        (clrhash (pumice--rels vault))
        (maphash (lambda (_ note)
                   (push note (gethash (downcase (pumice-note-name note))
                                       (pumice--names vault)))
                   (puthash (downcase (pumice-note-rel note)) note
                            (pumice--rels vault)))
                 notes)
        (cl-incf (pumice--tick vault)))
      (setf (pumice--last-scan vault) (float-time))))
  vault)

(defun pumice-notes (vault)
  "Return VAULT's notes, most recently modified first."
  (sort (hash-table-values (pumice--notes vault))
        (lambda (a b) (time-less-p (pumice-note-mtime b) (pumice-note-mtime a)))))

(defun pumice-note-at (vault path)
  "Return VAULT's note for the file at PATH, or nil."
  (and path (gethash (expand-file-name path) (pumice--notes vault))))

;;; Link resolution

(defun pumice--note-dir (note)
  "Return NOTE's directory relative to the vault root, downcased."
  (downcase (or (file-name-directory (pumice-note-rel note)) "")))

(defun pumice--closest (candidates from)
  "Pick from CANDIDATES the note Obsidian would: FROM's folder, else shortest."
  (or (and from (cdr candidates)
           (cl-find (pumice--note-dir from) candidates
                    :key #'pumice--note-dir :test #'equal))
      (car (sort (copy-sequence candidates)
                 (lambda (a b) (< (length (pumice-note-rel a))
                                  (length (pumice-note-rel b))))))))

(defun pumice-resolve (vault target &optional from)
  "Return the note in VAULT that link TARGET points to, or nil.
FROM is the note containing the link.  It settles ties between notes that
share a name and anchors relative paths.  An empty TARGET, as in
[[#Heading]], is FROM itself."
  (let ((target (downcase (string-remove-suffix ".md" (string-trim target)))))
    (cond
     ((string-empty-p target) from)
     ((not (string-search "/" target))
      (pumice--closest (gethash target (pumice--names vault)) from))
     ((gethash (string-remove-prefix "/" target) (pumice--rels vault)))
     ((and from
           (pumice-note-at
            vault (concat (expand-file-name
                           target (file-name-directory (pumice-note-path from)))
                          ".md"))))
     (t (let ((suffix (concat "/" target)) matches)
          (maphash (lambda (rel note)
                     (when (string-suffix-p suffix rel) (push note matches)))
                   (pumice--rels vault))
          (pumice--closest matches from))))))

(defun pumice-resolve-file (vault target)
  "Return the absolute path of non-note file TARGET in VAULT, or nil."
  (let* ((target (downcase (string-trim target)))
         (hit (cl-find-if
               (lambda (rel)
                 (let ((rel (downcase rel)))
                   (or (equal rel target)
                       (string-suffix-p (concat "/" target) rel)
                       (equal (file-name-nondirectory rel) target))))
               (pumice--files vault))))
    (and hit (expand-file-name hit (pumice--root vault)))))

(defun pumice-backlinks (vault note)
  "Return (SOURCE . LINK) pairs for every link in VAULT that reaches NOTE."
  (unless (eql (pumice--backlinks-tick vault) (pumice--tick vault))
    (let ((table (make-hash-table :test 'equal)))
      (maphash
       (lambda (_ source)
         (dolist (link (pumice-note-links source))
           (when-let* ((dest (pumice-resolve vault (pumice-link-target link)
                                             source)))
             (push (cons source link) (gethash (pumice-note-path dest) table)))))
       (pumice--notes vault))
      (setf (pumice--backlinks vault) table
            (pumice--backlinks-tick vault) (pumice--tick vault))))
  (reverse (gethash (pumice-note-path note) (pumice--backlinks vault))))

(defun pumice-link-name (vault note &optional from)
  "Return the shortest link target that reaches NOTE in VAULT from FROM."
  (if (eq (pumice-resolve vault (pumice-note-name note) from) note)
      (pumice-note-name note)
    (pumice-note-rel note)))

;;; Dates

(defconst pumice--moment-tokens
  '(("YYYY" . "%Y") ("yyyy" . "%Y") ("YY" . "%y") ("MMMM" . "%B")
    ("MMM" . "%b") ("MM" . "%m") ("M" . "%-m") ("DD" . "%d") ("D" . "%-d")
    ("dddd" . "%A") ("ddd" . "%a") ("HH" . "%H") ("mm" . "%M") ("ss" . "%S")
    ("WW" . "%V") ("GGGG" . "%G"))
  "Moment.js date tokens Obsidian uses, with `format-time-string' equivalents.")

(defun pumice-format-date (format time)
  "Format TIME with Moment.js FORMAT string, as Obsidian would."
  (let ((case-fold-search nil)
        (regexp (concat "\\[\\([^]]*\\)\\]\\|"
                        (regexp-opt (mapcar #'car pumice--moment-tokens)))))
    (replace-regexp-in-string
     regexp
     (lambda (token)
       (if (string-prefix-p "[" token)
           (substring token 1 -1)
         (format-time-string (cdr (assoc token pumice--moment-tokens)) time)))
     format t t)))

(defun pumice-daily-path (vault time)
  "Return the path of VAULT's daily note for TIME."
  (expand-file-name
   (concat (pumice-format-date (pumice-setting vault :daily-format) time) ".md")
   (expand-file-name (or (pumice-setting vault :daily-folder) "")
                     (pumice--root vault))))

(provide 'pumice-core)
;;; pumice-core.el ends here
