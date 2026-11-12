;;; pumice-cli.el --- Command-line access to a vault -*- lexical-binding: t; -*-

;;; Commentary:

;; The `notes' command (bin/notes) runs this file in a batch Emacs.  It gives
;; scripts and coding agents the index the editor uses: link resolution,
;; backlinks, properties, daily notes and renames that rewrite links.  It
;; needs neither a running Emacs nor Obsidian.
;;
;; `pumice-cli-run' is the whole command and prints to `standard-output'.
;; `pumice-cli-main' wraps it for the command line.

;;; Code:

(require 'pumice)
(require 'pumice-commands)
(require 'pumice-refactor)

(define-error 'pumice-cli-usage "Wrong usage")

(defvar pumice-cli--opts nil "Options of the current run, as an alist.")

(defconst pumice-cli--usage "\
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

(defconst pumice-cli--option-kinds
  '(("--vault" . value) ("--folder" . value) ("--tag" . value)
    ("--where" . multi) ("--limit" . value) ("--show" . value)
    ("--template" . value)
    ("--json") ("--abs") ("--help") ("--templates") ("--done") ("--all")
    ("--path") ("--read") ("--stdin"))
  "Every option, with `value' if it takes one and `multi' if it repeats.")

(defconst pumice-cli--filters '("--folder" "--tag" "--where" "--limit" "--templates")
  "The options that narrow a listing.")

(defconst pumice-cli--commands
  `(("vaults" pumice-cli--vaults 0 0)
    ("root" pumice-cli--root 0 0)
    ("config" pumice-cli--config 0 0)
    ("list" pumice-cli--list 0 0 "--show" ,@pumice-cli--filters)
    ("tags" pumice-cli--tags 0 0 ,@pumice-cli--filters)
    ("tasks" pumice-cli--tasks 0 1 "--done" "--all" ,@pumice-cli--filters)
    ("path" pumice-cli--path 1 1)
    ("read" pumice-cli--read 1 1)
    ("info" pumice-cli--info 1 1)
    ("links" pumice-cli--links 1 1)
    ("backlinks" pumice-cli--backlinks 1 1 "--limit")
    ("unresolved" pumice-cli--unresolved 0 0 ,@pumice-cli--filters)
    ("orphans" pumice-cli--orphans 0 0 ,@pumice-cli--filters)
    ("deadends" pumice-cli--deadends 0 0 ,@pumice-cli--filters)
    ("daily" pumice-cli--daily 0 1 "--path" "--read")
    ("log" pumice-cli--log 1 nil)
    ("new" pumice-cli--new 1 1 "--template" "--folder" "--stdin")
    ("set" pumice-cli--set 2 nil)
    ("unset" pumice-cli--unset 2 nil)
    ("rename" pumice-cli--rename 2 2)
    ("trash" pumice-cli--trash 1 1))
  "Each command as (NAME FUNCTION MIN-ARGS MAX-ARGS . OPTIONS).
A MAX-ARGS of nil means any number.  --vault, --json, --abs and --help
are accepted everywhere.")

(defun pumice-cli--usage-error (format &rest args)
  "Signal a usage error with a message made from FORMAT and ARGS."
  (signal 'pumice-cli-usage (list (apply #'format format args))))

(defun pumice-cli--parse (args)
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
                 (kind (or (assoc name pumice-cli--option-kinds)
                           (pumice-cli--usage-error "Unknown option %s" name))))
            (if (null (cdr kind))
                (push (cons name t) opts)
              (let ((value (cond (at (substring arg (1+ at)))
                                 (args (pop args))
                                 (t (pumice-cli--usage-error
                                     "%s needs a value" name)))))
                (if (eq (cdr kind) 'multi)
                    (push value (alist-get name opts nil nil #'equal))
                  (push (cons name value) opts))))))
         (t (push arg rest)))))
    (cons opts (nreverse rest))))

(defun pumice-cli--opt (name)
  "Return the value of option NAME in this run, or nil."
  (cdr (assoc name pumice-cli--opts)))

;;; Output

(defun pumice-cli--json (object)
  "Return OBJECT as a line of JSON text."
  ;; `json-serialize' returns bytes, which would be encoded a second time
  ;; on their way out.
  (with-temp-buffer
    (json-insert object)
    (insert "\n")
    (buffer-string)))

(defun pumice-cli--emit (items plain)
  "Print ITEMS, a list of alists: as a JSON array, or a line each from PLAIN."
  (let ((items (if-let* ((limit (pumice-cli--opt "--limit")))
                   (if (string-match-p "\\`[0-9]+\\'" limit)
                       (take (string-to-number limit) items)
                     (pumice-cli--usage-error "--limit takes a number, not %s"
                                              limit))
                 items)))
    (if (pumice-cli--opt "--json")
        (princ (pumice-cli--json (vconcat items)))
      (dolist (item items)
        (princ (funcall plain item))
        (terpri)))))

(defun pumice-cli--emit-one (item plain)
  "Print the alist ITEM as a JSON object, or as the string PLAIN."
  (princ (if (pumice-cli--opt "--json") (pumice-cli--json item) plain)))

(defun pumice-cli--write (text path)
  "Create the file PATH holding TEXT, along with any missing folders."
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil path nil 'silent)))

(defun pumice-cli--rel (vault path)
  "Return PATH as listings show it: from VAULT's root unless --abs is on."
  (if (pumice-cli--opt "--abs")
      path
    (file-relative-name path (pumice--root vault))))

(defun pumice-cli--props-json (props)
  "Return the property alist PROPS in the shape `json-serialize' wants."
  (let (result)
    (pcase-dolist (`(,key . ,value) props)
      (unless (assq (intern key) result)
        (push (cons (intern key) (if (listp value) (vconcat value) value))
              result)))
    (nreverse result)))

(defun pumice-cli--time (time)
  "Return TIME as an ISO 8601 string."
  (format-time-string "%FT%T%z" time))

;;; Finding the vault and its notes

(defun pumice-cli--vault-name (root)
  "Return the name of the vault at ROOT: its folder's name."
  (file-name-nondirectory (directory-file-name root)))

(defun pumice-cli--vault ()
  "Return the vault this run is about."
  (let ((spec (or (pumice-cli--opt "--vault") (getenv "NOTES_VAULT"))))
    (pumice-vault-at
     (cond
      ((or (null spec) (string-empty-p spec))
       (or (pumice-root-for default-directory)
           (ignore-errors (pumice--default-root))
           (user-error "No vault found.  Pass --vault DIR or set NOTES_VAULT")))
      ((cl-find spec (pumice-vault-roots)
                :test (lambda (name root)
                        (string-equal-ignore-case
                         name (pumice-cli--vault-name root)))))
      ((file-directory-p spec) (file-name-as-directory (expand-file-name spec)))
      (t (user-error "No vault called %s.  Known vaults: %s" spec
                     (mapconcat #'pumice-cli--vault-name (pumice-vault-roots)
                                ", ")))))))

(defun pumice-cli--find (vault name)
  "Return the note NAME means in VAULT, or nil.
NAME can be a file path, a path from the vault root, anything a link
could say, or an alias."
  (or (pumice-note-at vault (expand-file-name name))
      (pumice-note-at vault (expand-file-name name (pumice--root vault)))
      (pumice-resolve vault name)
      (cl-find-if (lambda (note)
                    (member-ignore-case name (pumice-note-aliases note)))
                  (pumice-notes vault))))

(defun pumice-cli--note (vault name)
  "Return the note NAME means in VAULT, or signal an error naming near misses."
  (let ((note (pumice-cli--find vault name))
        (same (gethash (downcase name) (pumice--names vault))))
    (cond
     ((null note)
      (let ((near (cl-remove-if-not
                   (lambda (other)
                     (string-search (downcase name)
                                    (downcase (pumice-note-name other))))
                   (pumice-notes vault))))
        (user-error "No note called %s%s" name
                    (if near
                        (format ".  Close: %s"
                                (mapconcat #'pumice-note-rel (take 5 near) ", "))
                      ""))))
     ((cdr same)
      (message "notes: %d notes are called %s; using %s.md" (length same) name
               (pumice-note-rel note))))
    note))

(defun pumice-cli--under-p (rel folder)
  "Non-nil if the vault-relative path REL is inside FOLDER."
  (string-prefix-p (downcase (file-name-as-directory (string-trim folder "/+" "/+")))
                   (downcase rel)))

(defun pumice-cli--where (expr)
  "Return a predicate on a property alist for the --where expression EXPR."
  (let ((match (lambda (props key value)
                 (let ((have (cdr (assoc key props))))
                   (if (listp have) (member value have) (equal value have))))))
    (cond
     ((string-match "\\`\\([^=!]+\\)\\(!=\\|==?\\)\\(.*\\)\\'" expr)
      (let ((key (string-trim (match-string 1 expr)))
            (negate (equal (match-string 2 expr) "!="))
            (value (pumice--yaml-scalar (match-string 3 expr))))
        (lambda (props)
          (if negate
              (not (funcall match props key value))
            (funcall match props key value)))))
     ((string-prefix-p "!" expr)
      (let ((key (string-trim (substring expr 1))))
        (lambda (props) (member (cdr (assoc key props)) '(nil "")))))
     (t (let ((key (string-trim expr)))
          (lambda (props) (not (member (cdr (assoc key props)) '(nil "")))))))))

(defun pumice-cli--notes (vault)
  "Return VAULT's notes that pass this run's filters, newest first."
  (let ((folder (pumice-cli--opt "--folder"))
        (tag (and (pumice-cli--opt "--tag")
                  (downcase (string-remove-prefix "#" (pumice-cli--opt "--tag")))))
        (wheres (mapcar #'pumice-cli--where (pumice-cli--opt "--where")))
        (templates (and (not (pumice-cli--opt "--templates"))
                        (pumice-setting vault :template-folder))))
    (cl-remove-if-not
     (lambda (note)
       (let ((rel (pumice-note-rel note)))
         (and (not (and templates (pumice-cli--under-p rel templates)))
              (or (null folder) (pumice-cli--under-p rel folder))
              (or (null tag)
                  (cl-some (lambda (have)
                             (let ((have (downcase have)))
                               (or (equal have tag)
                                   (string-prefix-p (concat tag "/") have))))
                           (pumice-note-tags note)))
              (cl-every (lambda (pred) (funcall pred (pumice-note-props note)))
                        wheres))))
     (pumice-notes vault))))

(defun pumice-cli--inside (vault path)
  "Return PATH, or signal an error if it is outside VAULT."
  (unless (string-prefix-p (pumice--root vault) (expand-file-name path))
    (user-error "%s is outside the vault" path))
  path)

(defun pumice-cli--stdin ()
  "Return everything on standard input."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents "/dev/stdin"))
    (buffer-string)))

;;; Looking around

(defun pumice-cli--vaults (_args)
  "List the known vaults."
  (let ((default (ignore-errors (pumice--default-root))))
    (pumice-cli--emit
     (mapcar (lambda (root)
               `((name . ,(pumice-cli--vault-name root))
                 (path . ,(directory-file-name root))
                 (default . ,(if (equal root default) t :false))))
             (pumice-vault-roots))
     (lambda (item)
       (format "%s %s\t%s" (if (eq t (alist-get 'default item)) "*" " ")
               (alist-get 'name item) (alist-get 'path item))))))

(defun pumice-cli--root (_args)
  "Print the vault's folder."
  (let ((root (directory-file-name (pumice--root (pumice-cli--vault)))))
    (pumice-cli--emit-one `((path . ,root)) (concat root "\n"))))

(defun pumice-cli--config (_args)
  "Print the settings the vault borrows from Obsidian."
  (let* ((vault (pumice-cli--vault))
         (item `((name . ,(pumice-cli--vault-name (pumice--root vault)))
                 (root . ,(directory-file-name (pumice--root vault)))
                 (notes . ,(hash-table-count (pumice--notes vault)))
                 (daily_folder . ,(or (pumice-setting vault :daily-folder) ""))
                 (daily_format . ,(pumice-setting vault :daily-format))
                 (daily_template . ,(or (pumice-setting vault :daily-template) ""))
                 (template_folder
                  . ,(or (pumice-setting vault :template-folder) ""))
                 (new_note_folder
                  . ,(or (pumice-setting vault :new-note-folder) "")))))
    (pumice-cli--emit-one
     item (mapconcat (lambda (pair) (format "%s: %s\n" (car pair) (cdr pair)))
                     item))))

(defun pumice-cli--column (note key)
  "Return what --show KEY prints for NOTE."
  (let ((value (or (cdr (assoc key (pumice-note-props note)))
                   (pcase key
                     ("modified" (format-time-string
                                  "%F %R" (pumice-note-mtime note)))
                     ("tags" (pumice-note-tags note))
                     ("aliases" (pumice-note-aliases note))
                     (_ "")))))
    (if (listp value) (string-join value ", ") value)))

(defun pumice-cli--list (_args)
  "List notes."
  (let* ((vault (pumice-cli--vault))
         (show (and (pumice-cli--opt "--show")
                    (split-string (pumice-cli--opt "--show") "," t "[ \t]+")))
         (rows (mapcar
                (lambda (note)
                  (cons `((path . ,(pumice-cli--rel vault (pumice-note-path note)))
                          (modified . ,(pumice-cli--time (pumice-note-mtime note)))
                          (tags . ,(vconcat (pumice-note-tags note)))
                          (properties
                           . ,(pumice-cli--props-json (pumice-note-props note))))
                        note))
                (pumice-cli--notes vault))))
    (pumice-cli--emit
     (mapcar #'car rows)
     (lambda (item)
       (let ((note (cdr (assq item rows))))
         (string-join (cons (alist-get 'path item)
                            (mapcar (lambda (key) (pumice-cli--column note key))
                                    show))
                      "\t"))))))

(defun pumice-cli--tags (_args)
  "List tags with their note counts."
  (let ((vault (pumice-cli--vault)))
    (pumice-cli--emit
     (mapcar (lambda (entry)
               `((tag . ,(car entry)) (count . ,(length (cdr entry)))))
             (pumice-tags vault (pumice-cli--notes vault)))
     (lambda (item)
       (format "%s\t%d" (alist-get 'tag item) (alist-get 'count item))))))

(defun pumice-cli--tasks (args)
  "List the checkbox tasks in the note named in ARGS, or in every note."
  (let* ((vault (pumice-cli--vault))
         (notes (if args
                    (list (pumice-cli--note vault (car args)))
                  (pumice-cli--notes vault)))
         (want (cond ((pumice-cli--opt "--all") 'all)
                     ((pumice-cli--opt "--done") 'done)
                     (t 'open)))
         items)
    (dolist (note notes)
      (with-temp-buffer
        (insert-file-contents (pumice-note-path note))
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
                    (push `((path . ,(pumice-cli--rel vault (pumice-note-path note)))
                            (line . ,line)
                            (done . ,(if done t :false))
                            (text . ,(match-string 3)))
                          items)))))))))
    (pumice-cli--emit
     (nreverse items)
     (lambda (item)
       (format "%s:%d: [%s] %s" (alist-get 'path item) (alist-get 'line item)
               (if (eq t (alist-get 'done item)) "x" " ")
               (alist-get 'text item))))))

(defun pumice-cli--path (args)
  "Print the absolute path of the note or attachment named in ARGS."
  (let* ((vault (pumice-cli--vault))
         (name (car args))
         ;; `pumice-cli--note' is what warns about a shared name, and what
         ;; reports a name that is neither a note nor a file.
         (path (or (and (pumice-cli--find vault name)
                        (pumice-note-path (pumice-cli--note vault name)))
                   (pumice-resolve-file vault name)
                   (pumice-note-path (pumice-cli--note vault name)))))
    (pumice-cli--emit-one `((path . ,path)) (concat path "\n"))))

(defun pumice-cli--read (args)
  "Print the text of the note named in ARGS."
  (let* ((vault (pumice-cli--vault))
         (path (pumice-note-path (pumice-cli--note vault (car args))))
         (text (with-temp-buffer
                 (insert-file-contents path)
                 (buffer-string))))
    (pumice-cli--emit-one `((path . ,path) (text . ,text)) text)))

(defun pumice-cli--incoming (vault note)
  "Return the backlinks of NOTE in VAULT that come from other notes."
  (cl-remove note (pumice-backlinks vault note) :key #'car))

(defun pumice-cli--info (args)
  "Print what the index knows about the note named in ARGS."
  (let* ((vault (pumice-cli--vault))
         (note (pumice-cli--note vault (car args)))
         (props (pumice-note-props note))
         (item `((path . ,(pumice-cli--rel vault (pumice-note-path note)))
                 (modified . ,(pumice-cli--time (pumice-note-mtime note)))
                 (aliases . ,(vconcat (pumice-note-aliases note)))
                 (tags . ,(vconcat (pumice-note-tags note)))
                 (links . ,(length (pumice-note-links note)))
                 (backlinks . ,(length (pumice-cli--incoming vault note)))
                 (properties . ,(pumice-cli--props-json props)))))
    (pumice-cli--emit-one
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

(defun pumice-cli--link-text (link)
  "Return LINK's target as it is written, with any heading."
  (concat (pumice-link-target link)
          (if-let* ((heading (pumice-link-heading link)))
              (concat "#" heading)
            "")))

(defun pumice-cli--links (args)
  "List the outgoing links of the note named in ARGS."
  (let* ((vault (pumice-cli--vault))
         (note (pumice-cli--note vault (car args))))
    (pumice-cli--emit
     (mapcar
      (lambda (link)
        (let* ((target (pumice-link-target link))
               (dest (if-let* ((to (pumice-resolve vault target note)))
                         (pumice-note-path to)
                       (pumice-resolve-file vault target))))
          `((line . ,(pumice-link-line link))
            (link . ,(pumice-cli--link-text link))
            (path . ,(if dest (pumice-cli--rel vault dest) :null)))))
      (pumice-note-links note))
     (lambda (item)
       (format "%d: [[%s]] -> %s" (alist-get 'line item) (alist-get 'link item)
               (if (eq :null (alist-get 'path item))
                   "(no such note)"
                 (alist-get 'path item)))))))

(defun pumice-cli--line-item (vault note link)
  "Return the alist for LINK as a line of NOTE in VAULT."
  `((path . ,(pumice-cli--rel vault (pumice-note-path note)))
    (line . ,(pumice-link-line link))
    (link . ,(pumice-cli--link-text link))
    (text . ,(pumice-link-text link))))

(defun pumice-cli--backlinks (args)
  "List the lines that link to the note named in ARGS."
  (let* ((vault (pumice-cli--vault))
         (note (pumice-cli--note vault (car args))))
    (pumice-cli--emit
     (mapcar (lambda (pair) (pumice-cli--line-item vault (car pair) (cdr pair)))
             (pumice-cli--incoming vault note))
     (lambda (item)
       (format "%s:%d: %s" (alist-get 'path item) (alist-get 'line item)
               (alist-get 'text item))))))

(defun pumice-cli--unresolved (_args)
  "List the links that lead to no note or file."
  (let ((vault (pumice-cli--vault)) items)
    (dolist (note (pumice-cli--notes vault))
      (dolist (link (pumice-note-links note))
        (let ((target (pumice-link-target link)))
          (unless (or (string-empty-p target)
                      (pumice-resolve vault target note)
                      (pumice-resolve-file vault target))
            (push (pumice-cli--line-item vault note link) items)))))
    (pumice-cli--emit
     (nreverse items)
     (lambda (item)
       (format "%s:%d: [[%s]]" (alist-get 'path item) (alist-get 'line item)
               (alist-get 'link item))))))

(defun pumice-cli--emit-notes (vault notes)
  "Print the paths of NOTES in VAULT."
  (pumice-cli--emit
   (mapcar (lambda (note)
             `((path . ,(pumice-cli--rel vault (pumice-note-path note)))))
           notes)
   (lambda (item) (alist-get 'path item))))

(defun pumice-cli--orphans (_args)
  "List the notes that no other note links to."
  (let ((vault (pumice-cli--vault)))
    (pumice-cli--emit-notes
     vault (cl-remove-if (lambda (note) (pumice-cli--incoming vault note))
                         (pumice-cli--notes vault)))))

(defun pumice-cli--deadends (_args)
  "List the notes that link to nothing."
  (let ((vault (pumice-cli--vault)))
    (pumice-cli--emit-notes
     vault (cl-remove-if #'pumice-note-links (pumice-cli--notes vault)))))

;;; Daily notes

(defun pumice-cli--date (spec)
  "Return the time the date SPEC means."
  (cond
   ((member spec '(nil "today")) (pumice--now))
   ((equal spec "yesterday") (pumice--days-from-now -1))
   ((equal spec "tomorrow") (pumice--days-from-now 1))
   ((string-match-p "\\`[+-][0-9]+\\'" spec)
    (pumice--days-from-now (string-to-number spec)))
   ((string-match
     "\\`\\([0-9]\\{4\\}\\)-\\([0-9][0-9]?\\)-\\([0-9][0-9]?\\)\\'" spec)
    ;; Noon, so that no change of clocks can land it on another day.
    (encode-time (list 0 0 12
                       (string-to-number (match-string 3 spec))
                       (string-to-number (match-string 2 spec))
                       (string-to-number (match-string 1 spec))
                       nil -1 nil)))
   (t (pumice-cli--usage-error "Cannot read %s as a date" spec))))

(defun pumice-cli--ensure-daily (vault time)
  "Return the path of VAULT's daily note for TIME, creating it if missing."
  (let ((path (pumice-daily-path vault time)))
    (unless (file-exists-p path)
      (pumice-cli--write (or (pumice--template-text
                              vault (pumice-setting vault :daily-template)
                              (file-name-base path) time)
                             "")
                         path)
      (pumice-refresh vault t))
    path))

(defun pumice-cli--daily (args)
  "Print the path, or with --read the text, of the daily note for ARGS."
  (let* ((vault (pumice-cli--vault))
         (time (pumice-cli--date (car args)))
         (path (pumice-daily-path vault time)))
    (cond
     ((pumice-cli--opt "--read")
      (unless (file-exists-p path)
        (user-error "There is no daily note at %s"
                    (file-relative-name path (pumice--root vault))))
      (pumice-cli--read (list path)))
     (t (unless (pumice-cli--opt "--path")
          (pumice-cli--ensure-daily vault time))
        (pumice-cli--emit-one `((path . ,path)
                                (exists . ,(if (file-exists-p path) t :false)))
                              (concat path "\n"))))))

(defun pumice-cli--log (args)
  "File the words in ARGS under the log heading of today's daily note."
  (let* ((vault (pumice-cli--vault))
         (now (pumice--now))
         (text (string-trim (string-join args " ")))
         (path (pumice-cli--ensure-daily vault now)))
    (when (string-empty-p text) (pumice-cli--usage-error "Nothing to log"))
    (pumice--edit-file path (lambda () (pumice--insert-log-entry text now)))
    (pumice-cli--emit-one `((path . ,path)) (concat path "\n"))))

;;; Changing things

(defun pumice-cli--template (vault name title time)
  "Return VAULT's template NAME filled in for TITLE and TIME."
  (let ((note (or (when-let* ((folder (pumice-setting vault :template-folder)))
                    (pumice-resolve vault (concat folder "/" name)))
                  (pumice-resolve vault name)
                  (user-error "No template called %s" name))))
    (pumice--template-text vault (pumice-note-rel note) title time)))

(defun pumice-cli--new (args)
  "Create the note named in ARGS."
  (let* ((vault (pumice-cli--vault))
         (name (string-remove-suffix ".md" (string-trim (car args))))
         (folder (pumice-cli--opt "--folder"))
         (path (progn
                 (when (string-empty-p name)
                   (pumice-cli--usage-error "A note needs a name"))
                 (pumice-cli--inside
                  vault
                  (if folder
                      (concat (expand-file-name
                               name (expand-file-name
                                     (string-trim folder "/+" "/+")
                                     (pumice--root vault)))
                              ".md")
                    (pumice--new-note-path vault name)))))
         (text (concat
                (if-let* ((template (pumice-cli--opt "--template")))
                    (pumice-cli--template vault template (file-name-base path)
                                          (pumice--now))
                  "")
                (if (pumice-cli--opt "--stdin") (pumice-cli--stdin) ""))))
    (when (file-exists-p path)
      (user-error "%s already exists"
                  (file-relative-name path (pumice--root vault))))
    (pumice-cli--write text path)
    (pumice-cli--emit-one `((path . ,path)) (concat path "\n"))))

(defun pumice-cli--edit-props (args edits)
  "Apply EDITS, a list of (KEY . VALUE), to the note named first in ARGS."
  (let* ((vault (pumice-cli--vault))
         (path (pumice-note-path (pumice-cli--note vault (car args)))))
    (pumice--edit-file path (lambda ()
                              (pcase-dolist (`(,key . ,value) edits)
                                (pumice-set-property key value))))
    (pumice-cli--emit-one `((path . ,path)) (concat path "\n"))))

(defun pumice-cli--set (args)
  "Set the KEY=VALUE properties in ARGS on the note named first."
  (pumice-cli--edit-props
   args
   (mapcar (lambda (pair)
             (let ((at (or (string-search "=" pair)
                           (pumice-cli--usage-error
                            "%s is not KEY=VALUE" pair))))
               (cons (string-trim (substring pair 0 at))
                     (substring pair (1+ at)))))
           (cdr args))))

(defun pumice-cli--unset (args)
  "Remove the properties named in ARGS from the note named first."
  (pumice-cli--edit-props args (mapcar #'list (cdr args))))

(defun pumice-cli--rename (args)
  "Rename or move the note named first in ARGS to the second."
  (let* ((vault (pumice-cli--vault))
         (note (pumice-cli--note vault (car args)))
         (new (string-remove-suffix ".md" (string-trim (cadr args))))
         (new-rel (cond
                   ((string-prefix-p "/" new) (string-remove-prefix "/" new))
                   ((string-search "/" new) new)
                   (t (concat (or (file-name-directory (pumice-note-rel note)) "")
                              new))))
         (path (pumice-cli--inside
                vault (concat (expand-file-name new-rel (pumice--root vault))
                              ".md"))))
    (when (equal new-rel (pumice-note-rel note))
      (user-error "%s is already called that" (pumice-note-rel note)))
    (let ((count (pumice-rename-note vault note new-rel)))
      (message "notes: %d link%s rewritten" count (if (= count 1) "" "s"))
      (pumice-cli--emit-one `((path . ,path) (links_rewritten . ,count))
                            (concat path "\n")))))

(defun pumice-cli--trash (args)
  "Move the note named in ARGS to the vault's trash."
  (let* ((vault (pumice-cli--vault))
         (note (pumice-cli--note vault (car args)))
         (links (length (pumice-cli--incoming vault note)))
         (path (pumice-trash-note vault note)))
    (unless (zerop links)
      (message "notes: %d link%s to it now lead%s nowhere" links
               (if (= links 1) "" "s") (if (= links 1) "s" "")))
    (pumice-cli--emit-one `((path . ,path) (dangling_links . ,links))
                          (concat path "\n"))))

;;; Entry points

(defun pumice-cli-run (args)
  "Run the notes command line ARGS, printing to `standard-output'.
Signal `pumice-cli-usage' for a malformed command and `user-error' for
one that cannot be carried out."
  (pcase-let* ((`(,opts . ,rest) (pumice-cli--parse args))
               (pumice-cli--opts opts)
               (name (car rest))
               (`(,_ ,fn ,min ,max . ,allowed)
                (assoc name pumice-cli--commands)))
    (cond
     ((or (pumice-cli--opt "--help") (member name '(nil "help")))
      (princ pumice-cli--usage))
     ((null fn)
      (pumice-cli--usage-error "Unknown command %s.  Try: notes help" name))
     (t
      (pcase-dolist (`(,opt . ,_) opts)
        (unless (member opt `("--vault" "--json" "--abs" ,@allowed))
          (pumice-cli--usage-error "%s does not take %s" name opt)))
      (let ((count (length (cdr rest))))
        (when (or (< count min) (and max (> count max)))
          (pumice-cli--usage-error
           "%s takes %s, not %d.  Try: notes help" name
           (cond ((null max) (format "at least %d argument%s" min
                                     (if (= min 1) "" "s")))
                 ((= min max) (format "%d argument%s" min (if (= min 1) "" "s")))
                 (t (format "%d to %d arguments" min max)))
           count)))
      (funcall fn (cdr rest))))))

(defun pumice-cli-main ()
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
         (progn (pumice-cli-run args) 0)
       (pumice-cli-usage (message "notes: %s" (cadr err)) 2)
       (error (message "notes: %s" (error-message-string err)) 1)))))

(provide 'pumice-cli)
;;; pumice-cli.el ends here
