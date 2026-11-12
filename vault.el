;;; vault.el --- Obsidian-compatible notes: index and link model -*- lexical-binding: t; -*-

;;; Commentary:

;; Works on Obsidian vaults in place. Notes stay plain Markdown with
;; [[wikilinks]], and the vault's own .obsidian settings decide where daily
;; notes, templates and new notes go, so Obsidian (desktop or phone) and this
;; can be used side by side on the same files.
;;
;; This file holds the data model: vault discovery, the note index, link
;; parsing and link resolution.  Commands are in vault-commands.el, the
;; editing mode and backlinks panel in vault-ui.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup vault nil
  "Obsidian-compatible personal wiki."
  :group 'text
  :prefix "vault-")

(defcustom vault-directories nil
  "Vault roots.  When nil, read them from `vault-obsidian-registry'."
  :type '(repeat directory))

(defcustom vault-obsidian-registry
  "~/Library/Application Support/obsidian/obsidian.json"
  "Obsidian's list of known vaults."
  :type 'file)

(defcustom vault-refresh-interval 2
  "Seconds for which a directory scan is trusted before rescanning."
  :type 'number)

(defvar vault-default-root nil
  "Root of the vault used when the current buffer is not inside one.")

(defvar-local vault-local-root nil
  "Vault root of a buffer that shows a vault without visiting a file in it.
The backlinks panel and the folder tree set it, so that commands run from
them act on the vault they are showing.")

(defvar vault--cache (make-hash-table :test 'equal)
  "Vault structs keyed by root directory.")

(cl-defstruct (vault (:constructor vault--make) (:conc-name vault--))
  root settings
  (notes (make-hash-table :test 'equal)) ; absolute path -> note
  (names (make-hash-table :test 'equal)) ; downcased basename -> notes
  (rels (make-hash-table :test 'equal))  ; downcased relative path -> note
  files                                  ; relative paths of non-note files
  backlinks backlinks-tick
  (tick 0) last-scan)

(cl-defstruct vault-note path rel name aliases tags links props mtime)

(cl-defstruct vault-link target heading alias line text embed)

;;; Vault discovery

(defun vault--read-json (file)
  "Parse FILE as JSON into alists, or return nil if that fails."
  (when (file-readable-p file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil)))))

(defun vault--registry ()
  "Return (ROOT . OPEN) pairs from Obsidian's vault registry."
  (let ((json (vault--read-json (expand-file-name vault-obsidian-registry))))
    (cl-loop for (_id . entry) in (alist-get 'vaults json)
             for path = (alist-get 'path entry)
             when (and path (file-directory-p path))
             collect (cons (file-name-as-directory path)
                           (alist-get 'open entry)))))

(defvar vault--roots nil
  "Roots read from the Obsidian registry, kept so it is parsed only once.
`vault-forget' clears it.")

(defun vault-roots ()
  "Return the root directory of every known vault."
  (if vault-directories
      (mapcar (lambda (d) (file-name-as-directory (expand-file-name d)))
              vault-directories)
    (or vault--roots
        (setq vault--roots (mapcar #'car (vault--registry))))))

(defun vault-forget ()
  "Drop every cached index and the list of vaults, to start from disk again."
  (interactive)
  (setq vault--roots nil)
  (clrhash vault--cache))

(defun vault-root-for (file)
  "Return the vault root containing FILE, or nil."
  (when file
    (let ((file (expand-file-name file)))
      (or (cl-find-if (lambda (root) (string-prefix-p root file))
                      (vault-roots))
          (when-let* ((dir (locate-dominating-file file ".obsidian")))
            (file-name-as-directory (expand-file-name dir)))))))

(defun vault--default-root ()
  "Return the fallback vault root, choosing one on first use."
  (or vault-default-root
      (setq vault-default-root
            (or (and (not vault-directories)
                     (car (cl-find-if #'cdr (vault--registry))))
                (car (vault-roots))
                (user-error "No vault found; set `vault-directories'")))))

(defun vault-get (root &optional no-refresh)
  "Return the vault rooted at ROOT.
The index is brought up to date first unless NO-REFRESH is non-nil."
  (let ((vault (or (gethash root vault--cache)
                   (puthash root (vault--make :root root) vault--cache))))
    (unless no-refresh (vault-refresh vault))
    vault))

(defun vault-current (&optional no-refresh)
  "Return the vault for the current buffer, else the default vault.
The index is brought up to date first unless NO-REFRESH is non-nil."
  (vault-get (or (vault-root-for (or buffer-file-name vault-local-root))
                 (vault--default-root))
             no-refresh))

;;; Settings borrowed from .obsidian

(defun vault--load-settings (vault)
  "Read the parts of VAULT's Obsidian configuration that matter here."
  (let* ((dir (expand-file-name ".obsidian/" (vault--root vault)))
         (app (vault--read-json (expand-file-name "app.json" dir)))
         (daily (vault--read-json (expand-file-name "daily-notes.json" dir)))
         (templates (vault--read-json (expand-file-name "templates.json" dir)))
         (nonempty (lambda (s) (and (stringp s) (not (string-empty-p s)) s))))
    (setf (vault--settings vault)
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

(defun vault-setting (vault key)
  "Return VAULT's setting KEY."
  (unless (vault--settings vault) (vault--load-settings vault))
  (plist-get (vault--settings vault) key))

;;; Parsing

(defconst vault--link-regexp
  (concat
   ;; [[target#heading|alias]], optionally an ![[embed]]
   "\\(?2:!\\)?\\[\\[\\(?3:[^]\n|#]*\\)\\(?:#\\(?4:[^]\n|]*\\)\\)?"
   "\\(?:|\\(?5:[^]\n]*\\)\\)?\\]\\]"
   ;; [text](relative/path.md#heading)
   "\\|\\[\\(?6:[^]\n]*\\)\\](\\(?7:[^)\n#]+\\.md\\)\\(?:#\\(?8:[^)\n]*\\)\\)?)")
  "Matches a wikilink (groups 2-5) or a Markdown link to a note (6-8).")

(defconst vault--scan-regexp
  (concat "^[ \t]*\\(?1:```\\|~~~\\)"
          "\\|" vault--link-regexp
          ;; #tag
          "\\|\\(?:^\\|[ \t(]\\)#\\(?9:[[:alpha:]_][[:alnum:]_/-]*\\)")
  "Matches code fences, wikilinks, Markdown links to notes, and tags.")

(defun vault--match-link ()
  "Build a link from the current `vault--link-regexp' match, or return nil."
  (cond
   ((match-beginning 3)
    (make-vault-link :target (string-trim (match-string-no-properties 3))
                     :heading (match-string-no-properties 4)
                     :alias (match-string-no-properties 5)
                     :embed (and (match-beginning 2) t)))
   ((and (match-beginning 7)
         (not (string-match-p "\\`[a-z]+:" (match-string-no-properties 7))))
    (make-vault-link :target (url-unhex-string (match-string-no-properties 7))
                     :heading (match-string-no-properties 8)
                     :alias (match-string-no-properties 6)))))

(defun vault--yaml-scalar (text)
  "Return YAML scalar TEXT as a string, without its quotes."
  (let ((text (string-trim text)))
    (cond ((string-match "\\`\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\"\\'" text)
           (replace-regexp-in-string "\\\\\\(.\\)" "\\1" (match-string 1 text)))
          ((string-match "\\`'\\(\\(?:[^']\\|''\\)*\\)'\\'" text)
           (string-replace "''" "'" (match-string 1 text)))
          (t text))))

(defconst vault--yaml-key-regexp
  "^\\([^] \t\n#:[-][^:\n]*\\):\\(?:[ \t]+\\(.*\\)\\|[ \t]*\\)$"
  "Matches a top-level frontmatter line: the key, then any inline value.")

(defun vault--frontmatter-bounds ()
  "Return (START . END) of the buffer's frontmatter lines, or nil.
START is after the opening --- line and END is at the closing one."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "---[ \t]*\n")
      (forward-line 1)
      (let ((start (point)))
        (when (re-search-forward "^---[ \t]*$" nil t)
          (cons start (match-beginning 0)))))))

(defun vault--frontmatter ()
  "Return the buffer's frontmatter as an alist of (KEY . VALUE).
VALUE is a string, or a list of strings for a YAML list.  This reads the
flat properties Obsidian writes, not all of YAML: a nested mapping is
skipped, and every scalar comes back as the text that was written."
  (when-let* ((bounds (vault--frontmatter-bounds)))
    (save-excursion
      (goto-char (car bounds))
      (let (props)
        (while (< (point) (cdr bounds))
          (if (not (looking-at vault--yaml-key-regexp))
              (forward-line 1)
            (let ((key (string-trim (match-string-no-properties 1)))
                  (inline (string-trim (or (match-string-no-properties 2) ""))))
              (forward-line 1)
              (push
               (cons key
                     (cond
                      ((string-match "\\`\\[\\(.*\\)\\]\\'" inline)
                       (cl-remove-if #'string-empty-p
                                     (mapcar #'vault--yaml-scalar
                                             (split-string (match-string 1 inline)
                                                           ","))))
                      ((not (string-empty-p inline)) (vault--yaml-scalar inline))
                      ((looking-at "[ \t]*-[ \t]")
                       (cl-loop while (and (< (point) (cdr bounds))
                                           (looking-at "[ \t]*-[ \t]+\\(.*\\)$"))
                                collect (vault--yaml-scalar
                                         (match-string-no-properties 1))
                                do (forward-line 1)))
                      (t "")))
               props))))
        (nreverse props)))))

(defun vault--prop-list (props key)
  "Return the value of KEY in the alist PROPS as a list of strings.
A scalar is split at commas, as Obsidian does for tags and aliases."
  (let ((value (cdr (assoc key props))))
    (cl-remove-if #'string-empty-p
                  (mapcar (lambda (item)
                            (string-remove-prefix "#" (string-trim item)))
                          (if (listp value) value (split-string value ","))))))

(defun vault--yaml-quote (value)
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

(defun vault-set-property (key value)
  "Set frontmatter property KEY of the note in the current buffer to VALUE.
VALUE is a string, a list of strings, or nil to remove the property.  A
note without frontmatter gets some.  Return non-nil if the text changed."
  (let ((line (cond ((null value) "")
                    ((listp value)
                     (concat key ":\n"
                             (mapconcat (lambda (item)
                                          (concat "  - " (vault--yaml-quote item)
                                                  "\n"))
                                        value)))
                    (t (format "%s: %s\n" key (vault--yaml-quote value)))))
        (bounds (vault--frontmatter-bounds))
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

(defun vault--line-text ()
  "Return the current line, trimmed and capped in length."
  (truncate-string-to-width
   (string-trim (buffer-substring-no-properties (pos-bol) (pos-eol)))
   240 nil nil t))

(defun vault--parse-buffer ()
  "Return (ALIASES TAGS LINKS PROPS) for the note text in the current buffer."
  (let* ((props (vault--frontmatter))
         (aliases (append (vault--prop-list props "aliases")
                          (vault--prop-list props "alias")))
         (tags (append (vault--prop-list props "tags")
                       (vault--prop-list props "tag")))
         links (in-fence nil) (case-fold-search nil))
    ;; Scan from the top again: Obsidian counts a [[link]] in a property,
    ;; such as parent: "[[Goals]]", like any other.
    (goto-char (point-min))
    (while (re-search-forward vault--scan-regexp nil t)
      (cond
       ((match-beginning 1) (setq in-fence (not in-fence)) (end-of-line))
       (in-fence (end-of-line))
       ((or (match-beginning 3) (match-beginning 7))
        (when-let* ((link (vault--match-link)))
          (setf (vault-link-line link) (line-number-at-pos)
                (vault-link-text link) (vault--line-text))
          (push link links)))
       ((match-beginning 9)
        (cl-pushnew (match-string-no-properties 9) tags :test #'equal))))
    (list aliases (delete-dups tags) (nreverse links) props)))

(defun vault--parse-file (path)
  "Return (ALIASES TAGS LINKS PROPS) for the note at PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (vault--parse-buffer)))

;;; Index

(defun vault--hidden-p (name)
  "Non-nil if file or directory NAME should stay out of the index."
  (or (string-prefix-p "." name)
      (string-suffix-p "~" name)
      (string-prefix-p "#" name)))

(defun vault--list-files (root)
  "Return every indexable file under ROOT as an absolute path."
  (cl-remove-if
   (lambda (f) (vault--hidden-p (file-name-nondirectory f)))
   (directory-files-recursively
    root "" nil
    (lambda (dir) (not (vault--hidden-p (file-name-nondirectory dir)))))))

(defun vault--rel (vault path)
  "Return PATH relative to VAULT's root, without a .md extension."
  (string-remove-suffix ".md" (file-relative-name path (vault--root vault))))

(defun vault-refresh (vault &optional force)
  "Bring VAULT's index up to date with the files on disk.
Scans are throttled by `vault-refresh-interval' unless FORCE is non-nil.
Only notes whose modification time changed are parsed again."
  (when (or force
            (null (vault--last-scan vault))
            (> (- (float-time) (vault--last-scan vault))
               vault-refresh-interval))
    (let ((notes (vault--notes vault))
          (seen (make-hash-table :test 'equal))
          (changed nil) files)
      (dolist (path (vault--list-files (vault--root vault)))
        (if (not (string-suffix-p ".md" path))
            (push (file-relative-name path (vault--root vault)) files)
          (puthash path t seen)
          (let ((mtime (file-attribute-modification-time
                        (file-attributes path)))
                (old (gethash path notes)))
            (unless (and old (equal mtime (vault-note-mtime old)))
              (pcase-let ((`(,aliases ,tags ,links ,props)
                           (condition-case nil (vault--parse-file path)
                             (error (list nil nil nil nil)))))
                (puthash path
                         (make-vault-note
                          :path path :rel (vault--rel vault path)
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
      (unless (equal files (vault--files vault))
        (setf (vault--files vault) files)
        (setq changed t))
      (when changed
        (clrhash (vault--names vault))
        (clrhash (vault--rels vault))
        (maphash (lambda (_ note)
                   (push note (gethash (downcase (vault-note-name note))
                                       (vault--names vault)))
                   (puthash (downcase (vault-note-rel note)) note
                            (vault--rels vault)))
                 notes)
        (cl-incf (vault--tick vault)))
      (setf (vault--last-scan vault) (float-time))))
  vault)

(defun vault-notes (vault)
  "Return VAULT's notes, most recently modified first."
  (sort (hash-table-values (vault--notes vault))
        (lambda (a b) (time-less-p (vault-note-mtime b) (vault-note-mtime a)))))

(defun vault-note-at (vault path)
  "Return VAULT's note for the file at PATH, or nil."
  (and path (gethash (expand-file-name path) (vault--notes vault))))

;;; Link resolution

(defun vault--note-dir (note)
  "Return NOTE's directory relative to the vault root, downcased."
  (downcase (or (file-name-directory (vault-note-rel note)) "")))

(defun vault--closest (candidates from)
  "Pick from CANDIDATES the note Obsidian would: FROM's folder, else shortest."
  (or (and from (cdr candidates)
           (cl-find (vault--note-dir from) candidates
                    :key #'vault--note-dir :test #'equal))
      (car (sort (copy-sequence candidates)
                 (lambda (a b) (< (length (vault-note-rel a))
                                  (length (vault-note-rel b))))))))

(defun vault-resolve (vault target &optional from)
  "Return the note in VAULT that link TARGET points to, or nil.
FROM is the note containing the link.  It settles ties between notes that
share a name and anchors relative paths.  An empty TARGET, as in
[[#Heading]], is FROM itself."
  (let ((target (downcase (string-remove-suffix ".md" (string-trim target)))))
    (cond
     ((string-empty-p target) from)
     ((not (string-search "/" target))
      (vault--closest (gethash target (vault--names vault)) from))
     ((gethash (string-remove-prefix "/" target) (vault--rels vault)))
     ((and from
           (vault-note-at
            vault (concat (expand-file-name
                           target (file-name-directory (vault-note-path from)))
                          ".md"))))
     (t (let ((suffix (concat "/" target)) matches)
          (maphash (lambda (rel note)
                     (when (string-suffix-p suffix rel) (push note matches)))
                   (vault--rels vault))
          (vault--closest matches from))))))

(defun vault-resolve-file (vault target)
  "Return the absolute path of non-note file TARGET in VAULT, or nil."
  (let* ((target (downcase (string-trim target)))
         (hit (cl-find-if
               (lambda (rel)
                 (let ((rel (downcase rel)))
                   (or (equal rel target)
                       (string-suffix-p (concat "/" target) rel)
                       (equal (file-name-nondirectory rel) target))))
               (vault--files vault))))
    (and hit (expand-file-name hit (vault--root vault)))))

(defun vault-backlinks (vault note)
  "Return (SOURCE . LINK) pairs for every link in VAULT that reaches NOTE."
  (unless (eql (vault--backlinks-tick vault) (vault--tick vault))
    (let ((table (make-hash-table :test 'equal)))
      (maphash
       (lambda (_ source)
         (dolist (link (vault-note-links source))
           (when-let* ((dest (vault-resolve vault (vault-link-target link)
                                            source)))
             (push (cons source link) (gethash (vault-note-path dest) table)))))
       (vault--notes vault))
      (setf (vault--backlinks vault) table
            (vault--backlinks-tick vault) (vault--tick vault))))
  (reverse (gethash (vault-note-path note) (vault--backlinks vault))))

(defun vault-link-name (vault note &optional from)
  "Return the shortest link target that reaches NOTE in VAULT from FROM."
  (if (eq (vault-resolve vault (vault-note-name note) from) note)
      (vault-note-name note)
    (vault-note-rel note)))

;;; Dates

(defconst vault--moment-tokens
  '(("YYYY" . "%Y") ("yyyy" . "%Y") ("YY" . "%y") ("MMMM" . "%B")
    ("MMM" . "%b") ("MM" . "%m") ("M" . "%-m") ("DD" . "%d") ("D" . "%-d")
    ("dddd" . "%A") ("ddd" . "%a") ("HH" . "%H") ("mm" . "%M") ("ss" . "%S")
    ("WW" . "%V") ("GGGG" . "%G"))
  "Moment.js date tokens Obsidian uses, with `format-time-string' equivalents.")

(defun vault-format-date (format time)
  "Format TIME with Moment.js FORMAT string, as Obsidian would."
  (let ((case-fold-search nil)
        (regexp (concat "\\[\\([^]]*\\)\\]\\|"
                        (regexp-opt (mapcar #'car vault--moment-tokens)))))
    (replace-regexp-in-string
     regexp
     (lambda (token)
       (if (string-prefix-p "[" token)
           (substring token 1 -1)
         (format-time-string (cdr (assoc token vault--moment-tokens)) time)))
     format t t)))

(defun vault-daily-path (vault time)
  "Return the path of VAULT's daily note for TIME."
  (expand-file-name
   (concat (vault-format-date (vault-setting vault :daily-format) time) ".md")
   (expand-file-name (or (vault-setting vault :daily-folder) "")
                     (vault--root vault))))

(provide 'vault)
;;; vault.el ends here
