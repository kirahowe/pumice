;;; vault-cli.el --- Command-line access to a vault -*- lexical-binding: t; -*-

;;; Commentary:

;; The `notes' command (bin/notes) runs this file in a batch Emacs.  It gives
;; scripts and coding agents the index the editor uses: link resolution,
;; backlinks, properties, daily notes and renames that rewrite links.  It
;; needs neither a running Emacs nor Obsidian.
;;
;; `vault-cli-run' is the whole command and prints to `standard-output'.
;; `vault-cli-main' wraps it for the command line.

;;; Code:

(require 'vault)
(require 'vault-commands)
(require 'vault-refactor)

(define-error 'vault-cli-usage "Wrong usage")

(defvar vault-cli--opts nil "Options of the current run, as an alist.")

(defconst vault-cli--usage "\
notes: read and change an Obsidian-format vault without Obsidian running.

Usage: notes [--vault NAME|DIR] [--json] [--abs] COMMAND [ARGS]

NOTE is a note's name as a [[link]] would write it, a path from the vault
root, or a file path.

Look around
  vaults                 the known vaults; * marks the default
  root                   the vault's folder
  config                 its folders for daily notes, templates and new notes
  list [FILTERS]         notes, most recently changed first
  tags [FILTERS]         every tag and how many notes carry it
  tasks [NOTE] [FILTERS] checkbox tasks still open; --done or --all for others
  path NOTE              absolute path of a note or attachment
  read NOTE              its text
  info NOTE              its tags, aliases, properties and link counts

Links
  links NOTE             its outgoing links and what each resolves to
  backlinks NOTE         every line elsewhere that links to it
  unresolved [FILTERS]   links to notes that do not exist
  orphans [FILTERS]      notes that nothing links to
  deadends [FILTERS]     notes that link to nothing

Daily notes
  daily [DATE]           path of the daily note, which is created from the
                         vault's template if it is missing
  daily [DATE] --path    the path only; nothing is created
  daily [DATE] --read    its text
  log TEXT               add \"- HH:MM TEXT\" under today's Log heading
  DATE is today, yesterday, tomorrow, YYYY-MM-DD, or a number of days
  such as -7 or +1.

Change
  new NAME [--template T] [--folder F] [--stdin]
                         create a note where the vault keeps new ones;
                         --stdin puts standard input after the template
  set NOTE KEY=VALUE...  set frontmatter properties
  unset NOTE KEY...      remove them
  rename NOTE NEW        rename in place when NEW has no /, else move to
                         that path from the vault root; links are rewritten
  trash NOTE             move it to the vault's .trash folder

FILTERS
  --folder F     only notes under folder F
  --tag T        only notes tagged T, or T/anything
  --where EXPR   KEY=VALUE, KEY!=VALUE, KEY (has a value) or !KEY (has
                 none).  Repeat it to require every one.  A list property
                 matches on any of its items.
  --limit N      at most N results
  --templates    include the template folder, which is otherwise left out
  --show KEYS    list only: add these properties as tab-separated columns.
                 modified, tags and aliases work here too.

The vault is the one named by --vault, else by $NOTES_VAULT, else the one
holding the current directory, else the default.  Lists print one result
per line with paths from the vault root; --abs makes those absolute and
--json prints JSON instead.  Commands that answer with a single file
print its absolute path.
"
  "What `notes help' prints.")

;;; Arguments

(defconst vault-cli--option-kinds
  '(("--vault" . value) ("--folder" . value) ("--tag" . value)
    ("--where" . multi) ("--limit" . value) ("--show" . value)
    ("--template" . value)
    ("--json") ("--abs") ("--help") ("--templates") ("--done") ("--all")
    ("--path") ("--read") ("--stdin"))
  "Every option, with `value' if it takes one and `multi' if it repeats.")

(defconst vault-cli--filters '("--folder" "--tag" "--where" "--limit" "--templates")
  "The options that narrow a listing.")

(defconst vault-cli--commands
  `(("vaults" vault-cli--vaults 0 0)
    ("root" vault-cli--root 0 0)
    ("config" vault-cli--config 0 0)
    ("list" vault-cli--list 0 0 "--show" ,@vault-cli--filters)
    ("tags" vault-cli--tags 0 0 ,@vault-cli--filters)
    ("tasks" vault-cli--tasks 0 1 "--done" "--all" ,@vault-cli--filters)
    ("path" vault-cli--path 1 1)
    ("read" vault-cli--read 1 1)
    ("info" vault-cli--info 1 1)
    ("links" vault-cli--links 1 1)
    ("backlinks" vault-cli--backlinks 1 1 "--limit")
    ("unresolved" vault-cli--unresolved 0 0 ,@vault-cli--filters)
    ("orphans" vault-cli--orphans 0 0 ,@vault-cli--filters)
    ("deadends" vault-cli--deadends 0 0 ,@vault-cli--filters)
    ("daily" vault-cli--daily 0 1 "--path" "--read")
    ("log" vault-cli--log 1 nil)
    ("new" vault-cli--new 1 1 "--template" "--folder" "--stdin")
    ("set" vault-cli--set 2 nil)
    ("unset" vault-cli--unset 2 nil)
    ("rename" vault-cli--rename 2 2)
    ("trash" vault-cli--trash 1 1))
  "Each command as (NAME FUNCTION MIN-ARGS MAX-ARGS . OPTIONS).
A MAX-ARGS of nil means any number.  --vault, --json, --abs and --help
are accepted everywhere.")

(defun vault-cli--usage-error (format &rest args)
  "Signal a usage error with a message made from FORMAT and ARGS."
  (signal 'vault-cli-usage (list (apply #'format format args))))

(defun vault-cli--parse (args)
  "Split ARGS into (OPTIONS . POSITIONALS).
OPTIONS is an alist of option name to its value, t for a flag, or a list
of values for one that repeats.  Only words starting with -- are options,
so a date such as -7 is a positional, and a lone -- ends the options."
  (let (opts rest)
    (while args
      (let ((arg (pop args)))
        (cond
         ((equal arg "--") (setq rest (append (reverse args) rest) args nil))
         ((string-prefix-p "--" arg)
          (let* ((at (string-search "=" arg))
                 (name (substring arg 0 at))
                 (kind (or (assoc name vault-cli--option-kinds)
                           (vault-cli--usage-error "Unknown option %s" name))))
            (if (null (cdr kind))
                (push (cons name t) opts)
              (let ((value (cond (at (substring arg (1+ at)))
                                 (args (pop args))
                                 (t (vault-cli--usage-error
                                     "%s needs a value" name)))))
                (if (eq (cdr kind) 'multi)
                    (push value (alist-get name opts nil nil #'equal))
                  (push (cons name value) opts))))))
         (t (push arg rest)))))
    (cons opts (nreverse rest))))

(defun vault-cli--opt (name)
  "Return the value of option NAME in this run, or nil."
  (cdr (assoc name vault-cli--opts)))

;;; Output

(defun vault-cli--json (object)
  "Return OBJECT as a line of JSON text."
  ;; `json-serialize' returns bytes, which would be encoded a second time
  ;; on their way out.
  (with-temp-buffer
    (json-insert object)
    (insert "\n")
    (buffer-string)))

(defun vault-cli--emit (items plain)
  "Print ITEMS, a list of alists: as a JSON array, or a line each from PLAIN."
  (let ((items (if-let* ((limit (vault-cli--opt "--limit")))
                   (if (string-match-p "\\`[0-9]+\\'" limit)
                       (take (string-to-number limit) items)
                     (vault-cli--usage-error "--limit takes a number, not %s"
                                             limit))
                 items)))
    (if (vault-cli--opt "--json")
        (princ (vault-cli--json (vconcat items)))
      (dolist (item items)
        (princ (funcall plain item))
        (terpri)))))

(defun vault-cli--emit-one (item plain)
  "Print the alist ITEM as a JSON object, or as the string PLAIN."
  (princ (if (vault-cli--opt "--json") (vault-cli--json item) plain)))

(defun vault-cli--write (text path)
  "Create the file PATH holding TEXT, along with any missing folders."
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil path nil 'silent)))

(defun vault-cli--rel (vault path)
  "Return PATH as listings show it: from VAULT's root unless --abs is on."
  (if (vault-cli--opt "--abs")
      path
    (file-relative-name path (vault--root vault))))

(defun vault-cli--props-json (props)
  "Return the property alist PROPS in the shape `json-serialize' wants."
  (let (result)
    (pcase-dolist (`(,key . ,value) props)
      (unless (assq (intern key) result)
        (push (cons (intern key) (if (listp value) (vconcat value) value))
              result)))
    (nreverse result)))

(defun vault-cli--time (time)
  "Return TIME as an ISO 8601 string."
  (format-time-string "%FT%T%z" time))

;;; Finding the vault and its notes

(defun vault-cli--vault-name (root)
  "Return the name of the vault at ROOT: its folder's name."
  (file-name-nondirectory (directory-file-name root)))

(defun vault-cli--vault ()
  "Return the vault this run is about."
  (let ((spec (or (vault-cli--opt "--vault") (getenv "NOTES_VAULT"))))
    (vault-get
     (cond
      ((or (null spec) (string-empty-p spec))
       (or (vault-root-for default-directory)
           (ignore-errors (vault--default-root))
           (user-error "No vault found.  Pass --vault DIR or set NOTES_VAULT")))
      ((cl-find spec (vault-roots)
                :test (lambda (name root)
                        (string-equal-ignore-case
                         name (vault-cli--vault-name root)))))
      ((file-directory-p spec) (file-name-as-directory (expand-file-name spec)))
      (t (user-error "No vault called %s.  Known vaults: %s" spec
                     (mapconcat #'vault-cli--vault-name (vault-roots) ", ")))))))

(defun vault-cli--find (vault name)
  "Return the note NAME means in VAULT, or nil.
NAME can be a file path, a path from the vault root, anything a link
could say, or an alias."
  (or (vault-note-at vault (expand-file-name name))
      (vault-note-at vault (expand-file-name name (vault--root vault)))
      (vault-resolve vault name)
      (cl-find-if (lambda (note)
                    (member-ignore-case name (vault-note-aliases note)))
                  (vault-notes vault))))

(defun vault-cli--note (vault name)
  "Return the note NAME means in VAULT, or signal an error naming near misses."
  (let ((note (vault-cli--find vault name))
        (same (gethash (downcase name) (vault--names vault))))
    (cond
     ((null note)
      (let ((near (cl-remove-if-not
                   (lambda (other)
                     (string-search (downcase name)
                                    (downcase (vault-note-name other))))
                   (vault-notes vault))))
        (user-error "No note called %s%s" name
                    (if near
                        (format ".  Close: %s"
                                (mapconcat #'vault-note-rel (take 5 near) ", "))
                      ""))))
     ((cdr same)
      (message "notes: %d notes are called %s; using %s.md" (length same) name
               (vault-note-rel note))))
    note))

(defun vault-cli--under-p (rel folder)
  "Non-nil if the vault-relative path REL is inside FOLDER."
  (string-prefix-p (downcase (file-name-as-directory (string-trim folder "/+" "/+")))
                   (downcase rel)))

(defun vault-cli--where (expr)
  "Return a predicate on a property alist for the --where expression EXPR."
  (let ((match (lambda (props key value)
                 (let ((have (cdr (assoc key props))))
                   (if (listp have) (member value have) (equal value have))))))
    (cond
     ((string-match "\\`\\([^=!]+\\)\\(!=\\|==?\\)\\(.*\\)\\'" expr)
      (let ((key (string-trim (match-string 1 expr)))
            (negate (equal (match-string 2 expr) "!="))
            (value (vault--yaml-scalar (match-string 3 expr))))
        (lambda (props)
          (if negate
              (not (funcall match props key value))
            (funcall match props key value)))))
     ((string-prefix-p "!" expr)
      (let ((key (string-trim (substring expr 1))))
        (lambda (props) (member (cdr (assoc key props)) '(nil "")))))
     (t (let ((key (string-trim expr)))
          (lambda (props) (not (member (cdr (assoc key props)) '(nil "")))))))))

(defun vault-cli--notes (vault)
  "Return VAULT's notes that pass this run's filters, newest first."
  (let ((folder (vault-cli--opt "--folder"))
        (tag (and (vault-cli--opt "--tag")
                  (downcase (string-remove-prefix "#" (vault-cli--opt "--tag")))))
        (wheres (mapcar #'vault-cli--where (vault-cli--opt "--where")))
        (templates (and (not (vault-cli--opt "--templates"))
                        (vault-setting vault :template-folder))))
    (cl-remove-if-not
     (lambda (note)
       (let ((rel (vault-note-rel note)))
         (and (not (and templates (vault-cli--under-p rel templates)))
              (or (null folder) (vault-cli--under-p rel folder))
              (or (null tag)
                  (cl-some (lambda (have)
                             (let ((have (downcase have)))
                               (or (equal have tag)
                                   (string-prefix-p (concat tag "/") have))))
                           (vault-note-tags note)))
              (cl-every (lambda (pred) (funcall pred (vault-note-props note)))
                        wheres))))
     (vault-notes vault))))

(defun vault-cli--inside (vault path)
  "Return PATH, or signal an error if it is outside VAULT."
  (unless (string-prefix-p (vault--root vault) (expand-file-name path))
    (user-error "%s is outside the vault" path))
  path)

(defun vault-cli--stdin ()
  "Return everything on standard input."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents "/dev/stdin"))
    (buffer-string)))

;;; Looking around

(defun vault-cli--vaults (_args)
  "List the known vaults."
  (let ((default (ignore-errors (vault--default-root))))
    (vault-cli--emit
     (mapcar (lambda (root)
               `((name . ,(vault-cli--vault-name root))
                 (path . ,(directory-file-name root))
                 (default . ,(if (equal root default) t :false))))
             (vault-roots))
     (lambda (item)
       (format "%s %s\t%s" (if (eq t (alist-get 'default item)) "*" " ")
               (alist-get 'name item) (alist-get 'path item))))))

(defun vault-cli--root (_args)
  "Print the vault's folder."
  (let ((root (directory-file-name (vault--root (vault-cli--vault)))))
    (vault-cli--emit-one `((path . ,root)) (concat root "\n"))))

(defun vault-cli--config (_args)
  "Print the settings the vault borrows from Obsidian."
  (let* ((vault (vault-cli--vault))
         (item `((name . ,(vault-cli--vault-name (vault--root vault)))
                 (root . ,(directory-file-name (vault--root vault)))
                 (notes . ,(hash-table-count (vault--notes vault)))
                 (daily_folder . ,(or (vault-setting vault :daily-folder) ""))
                 (daily_format . ,(vault-setting vault :daily-format))
                 (daily_template . ,(or (vault-setting vault :daily-template) ""))
                 (template_folder
                  . ,(or (vault-setting vault :template-folder) ""))
                 (new_note_folder
                  . ,(or (vault-setting vault :new-note-folder) "")))))
    (vault-cli--emit-one
     item (mapconcat (lambda (pair) (format "%s: %s\n" (car pair) (cdr pair)))
                     item))))

(defun vault-cli--column (note key)
  "Return what --show KEY prints for NOTE."
  (let ((value (or (cdr (assoc key (vault-note-props note)))
                   (pcase key
                     ("modified" (format-time-string
                                  "%F %R" (vault-note-mtime note)))
                     ("tags" (vault-note-tags note))
                     ("aliases" (vault-note-aliases note))
                     (_ "")))))
    (if (listp value) (string-join value ", ") value)))

(defun vault-cli--list (_args)
  "List notes."
  (let* ((vault (vault-cli--vault))
         (show (and (vault-cli--opt "--show")
                    (split-string (vault-cli--opt "--show") "," t "[ \t]+")))
         (rows (mapcar
                (lambda (note)
                  (cons `((path . ,(vault-cli--rel vault (vault-note-path note)))
                          (modified . ,(vault-cli--time (vault-note-mtime note)))
                          (tags . ,(vconcat (vault-note-tags note)))
                          (properties
                           . ,(vault-cli--props-json (vault-note-props note))))
                        note))
                (vault-cli--notes vault))))
    (vault-cli--emit
     (mapcar #'car rows)
     (lambda (item)
       (let ((note (cdr (assq item rows))))
         (string-join (cons (alist-get 'path item)
                            (mapcar (lambda (key) (vault-cli--column note key))
                                    show))
                      "\t"))))))

(defun vault-cli--tags (_args)
  "List tags with their note counts."
  (let ((vault (vault-cli--vault)))
    (vault-cli--emit
     (mapcar (lambda (entry)
               `((tag . ,(car entry)) (count . ,(length (cdr entry)))))
             (vault-tags vault (vault-cli--notes vault)))
     (lambda (item)
       (format "%s\t%d" (alist-get 'tag item) (alist-get 'count item))))))

(defun vault-cli--tasks (args)
  "List the checkbox tasks in the note named in ARGS, or in every note."
  (let* ((vault (vault-cli--vault))
         (notes (if args
                    (list (vault-cli--note vault (car args)))
                  (vault-cli--notes vault)))
         (want (cond ((vault-cli--opt "--all") 'all)
                     ((vault-cli--opt "--done") 'done)
                     (t 'open)))
         items)
    (dolist (note notes)
      (with-temp-buffer
        (insert-file-contents (vault-note-path note))
        (let ((in-fence nil) (line 1) (last (point-min)))
          (while (re-search-forward
                  (concat "^[ \t]*\\(?:\\(?1:```\\|~~~\\)\\|"
                          "\\(?:[-*+]\\|[0-9]+[.)]\\)[ \t]+"
                          "\\[\\(?2:.\\)\\][ \t]+\\(?3:.*\\)$\\)")
                  nil t)
            (cond
             ((match-beginning 1) (setq in-fence (not in-fence)))
             (in-fence)
             (t (let ((done (not (equal (match-string 2) " "))))
                  (when (or (eq want 'all) (eq done (eq want 'done)))
                    (setq line (+ line (count-lines last (pos-bol)))
                          last (pos-bol))
                    (push `((path . ,(vault-cli--rel vault (vault-note-path note)))
                            (line . ,line)
                            (done . ,(if done t :false))
                            (text . ,(match-string 3)))
                          items)))))))))
    (vault-cli--emit
     (nreverse items)
     (lambda (item)
       (format "%s:%d: [%s] %s" (alist-get 'path item) (alist-get 'line item)
               (if (eq t (alist-get 'done item)) "x" " ")
               (alist-get 'text item))))))

(defun vault-cli--path (args)
  "Print the absolute path of the note or attachment named in ARGS."
  (let* ((vault (vault-cli--vault))
         (name (car args))
         ;; `vault-cli--note' is what warns about a shared name, and what
         ;; reports a name that is neither a note nor a file.
         (path (or (and (vault-cli--find vault name)
                        (vault-note-path (vault-cli--note vault name)))
                   (vault-resolve-file vault name)
                   (vault-note-path (vault-cli--note vault name)))))
    (vault-cli--emit-one `((path . ,path)) (concat path "\n"))))

(defun vault-cli--read (args)
  "Print the text of the note named in ARGS."
  (let* ((vault (vault-cli--vault))
         (path (vault-note-path (vault-cli--note vault (car args))))
         (text (with-temp-buffer
                 (insert-file-contents path)
                 (buffer-string))))
    (vault-cli--emit-one `((path . ,path) (text . ,text)) text)))

(defun vault-cli--incoming (vault note)
  "Return the backlinks of NOTE in VAULT that come from other notes."
  (cl-remove note (vault-backlinks vault note) :key #'car))

(defun vault-cli--info (args)
  "Print what the index knows about the note named in ARGS."
  (let* ((vault (vault-cli--vault))
         (note (vault-cli--note vault (car args)))
         (props (vault-note-props note))
         (item `((path . ,(vault-cli--rel vault (vault-note-path note)))
                 (modified . ,(vault-cli--time (vault-note-mtime note)))
                 (aliases . ,(vconcat (vault-note-aliases note)))
                 (tags . ,(vconcat (vault-note-tags note)))
                 (links . ,(length (vault-note-links note)))
                 (backlinks . ,(length (vault-cli--incoming vault note)))
                 (properties . ,(vault-cli--props-json props)))))
    (vault-cli--emit-one
     item
     (concat
      (mapconcat (lambda (pair)
                   (format "%s: %s\n" (car pair)
                           (if (vectorp (cdr pair))
                               (string-join (cdr pair) ", ")
                             (cdr pair))))
                 (butlast item))
      "properties:\n"
      (mapconcat (lambda (pair)
                   (format "  %s: %s\n" (car pair)
                           (if (listp (cdr pair))
                               (string-join (cdr pair) ", ")
                             (cdr pair))))
                 props)))))

;;; Links

(defun vault-cli--link-text (link)
  "Return LINK's target as it is written, with any heading."
  (concat (vault-link-target link)
          (if-let* ((heading (vault-link-heading link)))
              (concat "#" heading)
            "")))

(defun vault-cli--links (args)
  "List the outgoing links of the note named in ARGS."
  (let* ((vault (vault-cli--vault))
         (note (vault-cli--note vault (car args))))
    (vault-cli--emit
     (mapcar
      (lambda (link)
        (let* ((target (vault-link-target link))
               (dest (if-let* ((to (vault-resolve vault target note)))
                         (vault-note-path to)
                       (vault-resolve-file vault target))))
          `((line . ,(vault-link-line link))
            (link . ,(vault-cli--link-text link))
            (path . ,(if dest (vault-cli--rel vault dest) :null)))))
      (vault-note-links note))
     (lambda (item)
       (format "%d: [[%s]] -> %s" (alist-get 'line item) (alist-get 'link item)
               (if (eq :null (alist-get 'path item))
                   "(no such note)"
                 (alist-get 'path item)))))))

(defun vault-cli--line-item (vault note link)
  "Return the alist for LINK as a line of NOTE in VAULT."
  `((path . ,(vault-cli--rel vault (vault-note-path note)))
    (line . ,(vault-link-line link))
    (link . ,(vault-cli--link-text link))
    (text . ,(vault-link-text link))))

(defun vault-cli--backlinks (args)
  "List the lines that link to the note named in ARGS."
  (let* ((vault (vault-cli--vault))
         (note (vault-cli--note vault (car args))))
    (vault-cli--emit
     (mapcar (lambda (pair) (vault-cli--line-item vault (car pair) (cdr pair)))
             (vault-cli--incoming vault note))
     (lambda (item)
       (format "%s:%d: %s" (alist-get 'path item) (alist-get 'line item)
               (alist-get 'text item))))))

(defun vault-cli--unresolved (_args)
  "List the links that lead to no note or file."
  (let ((vault (vault-cli--vault)) items)
    (dolist (note (vault-cli--notes vault))
      (dolist (link (vault-note-links note))
        (let ((target (vault-link-target link)))
          (unless (or (string-empty-p target)
                      (vault-resolve vault target note)
                      (vault-resolve-file vault target))
            (push (vault-cli--line-item vault note link) items)))))
    (vault-cli--emit
     (nreverse items)
     (lambda (item)
       (format "%s:%d: [[%s]]" (alist-get 'path item) (alist-get 'line item)
               (alist-get 'link item))))))

(defun vault-cli--emit-notes (vault notes)
  "Print the paths of NOTES in VAULT."
  (vault-cli--emit
   (mapcar (lambda (note)
             `((path . ,(vault-cli--rel vault (vault-note-path note)))))
           notes)
   (lambda (item) (alist-get 'path item))))

(defun vault-cli--orphans (_args)
  "List the notes that no other note links to."
  (let ((vault (vault-cli--vault)))
    (vault-cli--emit-notes
     vault (cl-remove-if (lambda (note) (vault-cli--incoming vault note))
                         (vault-cli--notes vault)))))

(defun vault-cli--deadends (_args)
  "List the notes that link to nothing."
  (let ((vault (vault-cli--vault)))
    (vault-cli--emit-notes
     vault (cl-remove-if #'vault-note-links (vault-cli--notes vault)))))

;;; Daily notes

(defun vault-cli--date (spec)
  "Return the time the date SPEC means."
  (cond
   ((member spec '(nil "today")) (vault--now))
   ((equal spec "yesterday") (vault--days-from-now -1))
   ((equal spec "tomorrow") (vault--days-from-now 1))
   ((string-match-p "\\`[+-][0-9]+\\'" spec)
    (vault--days-from-now (string-to-number spec)))
   ((string-match
     "\\`\\([0-9]\\{4\\}\\)-\\([0-9][0-9]?\\)-\\([0-9][0-9]?\\)\\'" spec)
    ;; Noon, so that no change of clocks can land it on another day.
    (encode-time (list 0 0 12
                       (string-to-number (match-string 3 spec))
                       (string-to-number (match-string 2 spec))
                       (string-to-number (match-string 1 spec))
                       nil -1 nil)))
   (t (vault-cli--usage-error "Cannot read %s as a date" spec))))

(defun vault-cli--ensure-daily (vault time)
  "Return the path of VAULT's daily note for TIME, creating it if missing."
  (let ((path (vault-daily-path vault time)))
    (unless (file-exists-p path)
      (vault-cli--write (or (vault--template-text
                             vault (vault-setting vault :daily-template)
                             (file-name-base path) time)
                            "")
                        path)
      (vault-refresh vault t))
    path))

(defun vault-cli--daily (args)
  "Print the path, or with --read the text, of the daily note for ARGS."
  (let* ((vault (vault-cli--vault))
         (time (vault-cli--date (car args)))
         (path (vault-daily-path vault time)))
    (cond
     ((vault-cli--opt "--read")
      (unless (file-exists-p path)
        (user-error "There is no daily note at %s"
                    (file-relative-name path (vault--root vault))))
      (vault-cli--read (list path)))
     (t (unless (vault-cli--opt "--path")
          (vault-cli--ensure-daily vault time))
        (vault-cli--emit-one `((path . ,path)
                               (exists . ,(if (file-exists-p path) t :false)))
                             (concat path "\n"))))))

(defun vault-cli--log (args)
  "File the words in ARGS under the log heading of today's daily note."
  (let* ((vault (vault-cli--vault))
         (now (vault--now))
         (text (string-trim (string-join args " ")))
         (path (vault-cli--ensure-daily vault now)))
    (when (string-empty-p text) (vault-cli--usage-error "Nothing to log"))
    (vault--edit-file path (lambda () (vault--insert-log-entry text now)))
    (vault-cli--emit-one `((path . ,path)) (concat path "\n"))))

;;; Changing things

(defun vault-cli--template (vault name title time)
  "Return VAULT's template NAME filled in for TITLE and TIME."
  (let ((note (or (when-let* ((folder (vault-setting vault :template-folder)))
                    (vault-resolve vault (concat folder "/" name)))
                  (vault-resolve vault name)
                  (user-error "No template called %s" name))))
    (vault--template-text vault (vault-note-rel note) title time)))

(defun vault-cli--new (args)
  "Create the note named in ARGS."
  (let* ((vault (vault-cli--vault))
         (name (string-remove-suffix ".md" (string-trim (car args))))
         (folder (vault-cli--opt "--folder"))
         (path (progn
                 (when (string-empty-p name)
                   (vault-cli--usage-error "A note needs a name"))
                 (vault-cli--inside
                  vault
                  (if folder
                      (concat (expand-file-name
                               name (expand-file-name
                                     (string-trim folder "/+" "/+")
                                     (vault--root vault)))
                              ".md")
                    (vault--new-note-path vault name)))))
         (text (concat
                (if-let* ((template (vault-cli--opt "--template")))
                    (vault-cli--template vault template (file-name-base path)
                                         (vault--now))
                  "")
                (if (vault-cli--opt "--stdin") (vault-cli--stdin) ""))))
    (when (file-exists-p path)
      (user-error "%s already exists"
                  (file-relative-name path (vault--root vault))))
    (vault-cli--write text path)
    (vault-cli--emit-one `((path . ,path)) (concat path "\n"))))

(defun vault-cli--edit-props (args edits)
  "Apply EDITS, a list of (KEY . VALUE), to the note named first in ARGS."
  (let* ((vault (vault-cli--vault))
         (path (vault-note-path (vault-cli--note vault (car args)))))
    (vault--edit-file path (lambda ()
                             (pcase-dolist (`(,key . ,value) edits)
                               (vault-set-property key value))))
    (vault-cli--emit-one `((path . ,path)) (concat path "\n"))))

(defun vault-cli--set (args)
  "Set the KEY=VALUE properties in ARGS on the note named first."
  (vault-cli--edit-props
   args
   (mapcar (lambda (pair)
             (let ((at (or (string-search "=" pair)
                           (vault-cli--usage-error
                            "%s is not KEY=VALUE" pair))))
               (cons (string-trim (substring pair 0 at))
                     (substring pair (1+ at)))))
           (cdr args))))

(defun vault-cli--unset (args)
  "Remove the properties named in ARGS from the note named first."
  (vault-cli--edit-props args (mapcar #'list (cdr args))))

(defun vault-cli--rename (args)
  "Rename or move the note named first in ARGS to the second."
  (let* ((vault (vault-cli--vault))
         (note (vault-cli--note vault (car args)))
         (new (string-remove-suffix ".md" (string-trim (cadr args))))
         (new-rel (cond
                   ((string-prefix-p "/" new) (string-remove-prefix "/" new))
                   ((string-search "/" new) new)
                   (t (concat (or (file-name-directory (vault-note-rel note)) "")
                              new))))
         (path (vault-cli--inside
                vault (concat (expand-file-name new-rel (vault--root vault))
                              ".md"))))
    (when (equal new-rel (vault-note-rel note))
      (user-error "%s is already called that" (vault-note-rel note)))
    (let ((count (vault-rename-note vault note new-rel)))
      (message "notes: %d link%s rewritten" count (if (= count 1) "" "s"))
      (vault-cli--emit-one `((path . ,path) (links_rewritten . ,count))
                           (concat path "\n")))))

(defun vault-cli--trash (args)
  "Move the note named in ARGS to the vault's trash."
  (let* ((vault (vault-cli--vault))
         (note (vault-cli--note vault (car args)))
         (links (length (vault-cli--incoming vault note)))
         (path (vault-trash-note vault note)))
    (unless (zerop links)
      (message "notes: %d link%s to it now lead%s nowhere" links
               (if (= links 1) "" "s") (if (= links 1) "s" "")))
    (vault-cli--emit-one `((path . ,path) (dangling_links . ,links))
                         (concat path "\n"))))

;;; Entry points

(defun vault-cli-run (args)
  "Run the notes command line ARGS, printing to `standard-output'.
Signal `vault-cli-usage' for a malformed command and `user-error' for
one that cannot be carried out."
  (pcase-let* ((`(,opts . ,rest) (vault-cli--parse args))
               (vault-cli--opts opts)
               (name (car rest))
               (`(,_ ,fn ,min ,max . ,allowed)
                (assoc name vault-cli--commands)))
    (cond
     ((or (vault-cli--opt "--help") (member name '(nil "help")))
      (princ vault-cli--usage))
     ((null fn)
      (vault-cli--usage-error "Unknown command %s.  Try: notes help" name))
     (t
      (pcase-dolist (`(,opt . ,_) opts)
        (unless (member opt `("--vault" "--json" "--abs" ,@allowed))
          (vault-cli--usage-error "%s does not take %s" name opt)))
      (let ((count (length (cdr rest))))
        (when (or (< count min) (and max (> count max)))
          (vault-cli--usage-error
           "%s takes %s, not %d.  Try: notes help" name
           (cond ((null max) (format "at least %d argument%s" min
                                     (if (= min 1) "" "s")))
                 ((= min max) (format "%d argument%s" min (if (= min 1) "" "s")))
                 (t (format "%d to %d arguments" min max)))
           count)))
      (funcall fn (cdr rest))))))

(defun vault-cli-main ()
  "Run the command line left in `command-line-args-left' and exit."
  (let ((args (mapcar (lambda (arg)
                        ;; Under a C locale the arguments arrive undecoded.
                        (if (multibyte-string-p arg)
                            arg
                          (decode-coding-string arg 'utf-8)))
                      (if (equal (car command-line-args-left) "--")
                          (cdr command-line-args-left)
                        command-line-args-left))))
    (setq command-line-args-left nil)
    (set-language-environment "UTF-8")
    (setq locale-coding-system 'utf-8
          ;; Nothing but the notes themselves should appear in a vault.
          create-lockfiles nil
          make-backup-files nil)
    (kill-emacs
     (condition-case err
         (progn (vault-cli-run args) 0)
       (vault-cli-usage (message "notes: %s" (cadr err)) 2)
       (error (message "notes: %s" (error-message-string err)) 1)))))

(provide 'vault-cli)
;;; vault-cli.el ends here
