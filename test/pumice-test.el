;;; pumice-test.el --- Tests for pumice -*- lexical-binding: t; -*-

;; Run them with `make test' from the repo root.
;;
;; Every test builds a throwaway vault under `temporary-file-directory', so
;; nothing here can touch a real one.

(require 'ert)
(require 'pumice)
(require 'pumice-cli)

;; evil advises primitives.  On a native-compiling Emacs each one would
;; start the compiler to build a trampoline, which a test run does not need.
(defvar native-comp-enable-subr-trampolines)
(setq native-comp-enable-subr-trampolines nil)

(pumice-global-mode 1)

(defconst pumice-test--files
  '((".obsidian/app.json"
     . "{\"newFileLocation\":\"folder\",\"newFileFolderPath\":\"Inbox\"}")
    (".obsidian/daily-notes.json"
     . "{\"format\":\"YYYY/MM/MMM D, yyyy\",\"folder\":\"Day Notes\",\"template\":\"Templates/Day note\"}")
    (".obsidian/templates.json" . "{\"folder\":\"Templates\"}")
    (".trash/Deleted.md" . "[[Home]]\n")
    ("Home.md"
     . "# Home\n\n[[Weekly Review]] and [[Ongoing work|Projects]]\n![[Follow-ups.base#Active]]\n[[Notes/Work/Trellis]] #gtd\n[[Nowhere]]\n")
    ("Weekly Review.md"
     . "---\naliases: [Review, \"Weekly\"]\ntags:\n  - gtd\n  - routine\n---\nBack to [[Home]].\n\n## Checklist\n\n- [ ] Empty the inbox\n")
    ("Ongoing work.md"
     . "See [[Home#Goals]] and [the review](Weekly%20Review.md).\n\n```\n[[Not a link]] #nottag\n```\n")
    ("Notes/Work/Trellis.md" . "Work notes. [[Clojure]] #work/project\n")
    ("Notes/Work/Clojure.md"
     . "---\nparent: \"[[Trellis]]\"\ncolour: \"#fff\"\n---\nThe work one.\n")
    ("Notes/Clojure.md" . "The general one. Mentions Trellis in passing.\n")
    ("Templates/Day note.md" . "## Log\n\n{{title}} on {{date}}\n")
    ("Day Notes/2026/08/Aug 7, 2026.md" . "## Log\n\n[[Home]]\n")
    ("Day Notes/2026/08/Aug 14, 2026.md" . "## Log\n")
    ("Follow-ups.base" . "views: []\n")
    ("Attachments/diagram.png" . "not really a png"))
  "Relative path and content of every file in the fixture vault.")

(defmacro pumice-test-with-vault (&rest body)
  "Run BODY with `v' bound to a freshly indexed fixture vault."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory
                 (file-truename (make-temp-file "pumice-test" t))))
          (pumice-vault-directories (list root))
          (pumice-default-root root)
          (pumice--cache (make-hash-table :test 'equal))
          (pumice-refresh-interval 0))
     (unwind-protect
         (progn
           (pcase-dolist (`(,rel . ,content) pumice-test--files)
             (let ((path (expand-file-name rel root)))
               (make-directory (file-name-directory path) t)
               (write-region content nil path nil 'silent)))
           (let ((v (pumice-current-vault)))
             (ignore v)
             ,@body))
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p root (buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun pumice-test--note (v rel)
  "Return the note at REL (with extension) in V."
  (pumice-note-at v (expand-file-name rel (pumice--root v))))

(defun pumice-test--read (v rel)
  "Return the content of REL in V as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name rel (pumice--root v)))
    (buffer-string)))

;;; Finding vaults

(ert-deftest pumice-test-registry-location ()
  "The registry is looked for where Obsidian keeps it on each system."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "XDG_CONFIG_HOME" nil)
    (setenv "APPDATA" nil)
    (let ((system-type 'darwin))
      (should (equal (list (expand-file-name
                            "~/Library/Application Support/obsidian/obsidian.json"))
                     (pumice--registry-candidates))))
    (let ((system-type 'gnu/linux))
      (should (equal (expand-file-name "~/.config/obsidian/obsidian.json")
                     (car (pumice--registry-candidates))))
      (should (= 3 (length (pumice--registry-candidates))))
      (setenv "XDG_CONFIG_HOME" "/xdg")
      (should (equal (expand-file-name "/xdg/obsidian/obsidian.json")
                     (car (pumice--registry-candidates)))))
    (let ((system-type 'windows-nt))
      (setenv "APPDATA" "/users/me/AppData/Roaming")
      (should (equal (list (expand-file-name
                            "/users/me/AppData/Roaming/obsidian/obsidian.json"))
                     (pumice--registry-candidates))))))

(ert-deftest pumice-test-vaults-from-the-registry ()
  "Vaults come from Obsidian's registry, and the open one is the default."
  (pumice-test-with-vault
    (let* ((other (file-name-as-directory
                   (file-truename (make-temp-file "pumice-other" t))))
           (registry (make-temp-file "pumice-registry" nil ".json"))
           (pumice-vault-directories nil)
           (pumice-obsidian-registry registry)
           (pumice--vault-roots nil)
           (pumice-default-root nil))
      (unwind-protect
          (progn
            (with-temp-file registry
              (insert (json-serialize
                       `((vaults
                          . ((a . ((path . ,(directory-file-name other))))
                             (b . ((path . ,(directory-file-name root))
                                   (open . t)))
                             (c . ((path . "/no/such/folder")))))))))
            (should (equal (list other root) (pumice-vault-roots)))
            (should (equal root (pumice--default-root))))
        (delete-directory other t)
        (delete-file registry)))))

(ert-deftest pumice-test-no-registry ()
  "Without Obsidian's registry there are no vaults until some are named."
  (let ((pumice-vault-directories nil)
        (pumice-obsidian-registry nil)
        (pumice--vault-roots nil)
        (pumice-default-root nil))
    (cl-letf (((symbol-function 'pumice--registry-candidates)
               (lambda () '("/no/such/obsidian.json"))))
      (should-not (pumice-vault-roots))
      (should-error (pumice--default-root) :type 'user-error))))

(ert-deftest pumice-test-a-folder-with-obsidian-settings-is-a-vault ()
  "A file under a .obsidian folder is in a vault, registered or not."
  (pumice-test-with-vault
    (let ((pumice-vault-directories nil)
          (pumice-obsidian-registry nil)
          (pumice--vault-roots nil))
      (cl-letf (((symbol-function 'pumice--registry-candidates)
                 (lambda () '("/no/such/obsidian.json"))))
        (should (equal root (pumice-root-for
                             (expand-file-name "Notes/Clojure.md" root))))))))

(ert-deftest pumice-test-open-in-obsidian ()
  "A note is handed to Obsidian by its obsidian:// address."
  (pumice-test-with-vault
    (with-current-buffer
        (find-file-noselect (expand-file-name "Weekly Review.md" root))
      (let (uri)
        (cl-letf (((symbol-function 'pumice--open-with-system)
                   (lambda (address) (setq uri address))))
          (pumice-open-in-obsidian))
        (should (string-match-p
                 "\\`obsidian://open\\?path=.*Weekly%20Review\\.md\\'" uri))))))

;;; Index

(ert-deftest pumice-test-index-skips-hidden-directories ()
  (pumice-test-with-vault
    (should (= 9 (hash-table-count (pumice--notes v))))
    (should-not (pumice-test--note v ".trash/Deleted.md"))
    (should (member "Follow-ups.base" (pumice--files v)))))

(ert-deftest pumice-test-frontmatter-and-tags ()
  (pumice-test-with-vault
    (let ((review (pumice-test--note v "Weekly Review.md")))
      (should (equal '("Review" "Weekly") (pumice-note-aliases review)))
      (should (equal '("gtd" "routine") (pumice-note-tags review))))
    (should (equal '("work/project")
                   (pumice-note-tags
                    (pumice-test--note v "Notes/Work/Trellis.md"))))))

(ert-deftest pumice-test-links-in-properties-count ()
  (pumice-test-with-vault
    (let ((note (pumice-test--note v "Notes/Work/Clojure.md")))
      (should (equal '("Trellis")
                     (mapcar #'pumice-link-target (pumice-note-links note))))
      (should-not (pumice-note-tags note)))))

(ert-deftest pumice-test-links-skip-code-fences ()
  (pumice-test-with-vault
    (let ((note (pumice-test--note v "Ongoing work.md")))
      (should (equal '("Home" "Weekly Review.md")
                     (mapcar #'pumice-link-target (pumice-note-links note))))
      (should (equal "Goals"
                     (pumice-link-heading (car (pumice-note-links note)))))
      (should-not (pumice-note-tags note)))))

(ert-deftest pumice-test-refresh-picks-up-changes ()
  (pumice-test-with-vault
    (let ((tick (pumice--tick v)))
      (pumice-refresh v t)
      (should (= tick (pumice--tick v)))
      (write-region "[[Home]]\n" nil (expand-file-name "New.md" root))
      (delete-file (expand-file-name "Notes/Clojure.md" root))
      (pumice-refresh v t)
      (should (> (pumice--tick v) tick))
      (should (pumice-test--note v "New.md"))
      (should-not (pumice-test--note v "Notes/Clojure.md")))))

;;; Resolution

(ert-deftest pumice-test-resolve ()
  (pumice-test-with-vault
    (let ((home (pumice-test--note v "Home.md"))
          (trellis (pumice-test--note v "Notes/Work/Trellis.md")))
      (should (eq home (pumice-resolve v "home")))
      (should (eq trellis (pumice-resolve v "Notes/Work/Trellis")))
      (should (eq trellis (pumice-resolve v "Work/Trellis.md")))
      (should-not (pumice-resolve v "Nowhere"))
      (should (eq home (pumice-resolve v "" home)))
      ;; Two notes are called Clojure.  The link's own folder wins, and
      ;; without one the shorter path does.
      (should (equal "Notes/Work/Clojure"
                     (pumice-note-rel (pumice-resolve v "Clojure" trellis))))
      (should (equal "Notes/Clojure"
                     (pumice-note-rel (pumice-resolve v "Clojure" home)))))))

(ert-deftest pumice-test-resolve-file ()
  (pumice-test-with-vault
    (should (string-suffix-p "Attachments/diagram.png"
                             (pumice-resolve-file v "diagram.png")))
    (should (pumice-resolve-file v "Follow-ups.base"))
    (should-not (pumice-resolve-file v "missing.png"))))

(ert-deftest pumice-test-backlinks ()
  (pumice-test-with-vault
    (let ((sources (mapcar (lambda (pair) (pumice-note-name (car pair)))
                           (pumice-backlinks v (pumice-test--note v "Home.md")))))
      (should (equal '("Aug 7, 2026" "Ongoing work" "Weekly Review")
                     (sort sources #'string<))))
    ;; A Markdown link with an escaped space counts.
    (should (member "Ongoing work"
                    (mapcar (lambda (pair) (pumice-note-name (car pair)))
                            (pumice-backlinks
                             v (pumice-test--note v "Weekly Review.md")))))))

(ert-deftest pumice-test-link-name ()
  (pumice-test-with-vault
    (let ((home (pumice-test--note v "Home.md")))
      (should (equal "Weekly Review"
                     (pumice-link-name
                      v (pumice-test--note v "Weekly Review.md") home)))
      (should (equal "Notes/Work/Clojure"
                     (pumice-link-name
                      v (pumice-test--note v "Notes/Work/Clojure.md") home))))))

;;; Dates and settings

(ert-deftest pumice-test-format-date ()
  (let ((time (encode-time '(0 5 9 7 8 2026 nil -1 nil))))
    (should (equal "2026/08/Aug 7, 2026"
                   (pumice-format-date "YYYY/MM/MMM D, yyyy" time)))
    (should (equal "2026-08-07" (pumice-format-date "YYYY-MM-DD" time)))
    (should (equal "Day 07 at 09:05"
                   (pumice-format-date "[Day] DD [at] HH:mm" time)))))

(ert-deftest pumice-test-daily-path ()
  (pumice-test-with-vault
    (should (equal (expand-file-name "Day Notes/2026/08/Aug 7, 2026.md" root)
                   (pumice-daily-path
                    v (encode-time '(0 0 12 7 8 2026 nil -1 nil)))))
    (should (equal "Inbox" (pumice-setting v :new-note-folder)))))

;;; Following and inserting links

(defmacro pumice-test-in-note (rel &rest body)
  "Visit REL in the fixture vault `v' and run BODY there."
  (declare (indent 1) (debug t))
  `(with-current-buffer (find-file-noselect (expand-file-name ,rel root))
     (goto-char (point-min))
     ,@body))

(ert-deftest pumice-test-link-at-point ()
  (pumice-test-with-vault
    (pumice-test-in-note "Home.md"
      (should-not (pumice-link-at-point))
      (search-forward "Ongoing")
      (pcase-let ((`(,link ,beg ,end) (pumice-link-at-point)))
        (should (equal "Ongoing work" (pumice-link-target link)))
        (should (equal "Projects" (pumice-link-alias link)))
        (should (equal "[[Ongoing work|Projects]]"
                       (buffer-substring beg end)))))))

(ert-deftest pumice-test-follow ()
  (pumice-test-with-vault
    (save-window-excursion
      (pumice-test-in-note "Ongoing work.md"
        (search-forward "[[Home")
        (should (pumice-follow))
        (should (equal "Home.md" (file-name-nondirectory buffer-file-name))))
      ;; A dangling link starts the note where the vault keeps new ones,
      ;; without creating a file or a folder until it is saved.
      (pumice-test-in-note "Home.md"
        (search-forward "[[Nowhere")
        (should (pumice-follow))
        (should (equal (expand-file-name "Inbox/Nowhere.md" root)
                       buffer-file-name))
        (should-not (file-exists-p (expand-file-name "Inbox" root))))
      (pumice-test-in-note "Home.md"
        (search-forward "Follow-ups")
        (should (pumice-follow))
        (should (equal "Follow-ups.base"
                       (file-name-nondirectory buffer-file-name))))
      (pumice-test-in-note "Home.md"
        (should-not (pumice-follow))))))

(ert-deftest pumice-test-follow-link-only-acts-on-links ()
  "`pumice-follow-link' leaves a checkbox alone, and so does its key."
  (pumice-test-with-vault
    (save-window-excursion
      (pumice-test-in-note "Weekly Review.md"
        (search-forward "- [ ] Empty")
        (should-not (pumice-follow-link))
        (should (string-search "- [ ] Empty" (buffer-string)))
        ;; Off a link, the key is left to the major mode.
        (should-not (eq 'pumice-follow-link (key-binding (kbd "C-c C-o"))))
        (goto-char (point-min))
        (search-forward "[[Ho")
        (should (eq 'pumice-follow-link (key-binding (kbd "C-c C-o"))))
        (should (pumice-follow-link))
        (should (equal "Home.md" (file-name-nondirectory buffer-file-name)))))))

(ert-deftest pumice-test-following-leaves-a-way-back ()
  "After following a link, `xref-go-back' returns to where it was."
  (pumice-test-with-vault
    (save-window-excursion
      (switch-to-buffer
       (find-file-noselect (expand-file-name "Ongoing work.md" root)))
      (goto-char (point-min))
      (search-forward "[[Home")
      (let ((origin (point)))
        (should (pumice-follow))
        (should (equal "Home.md" (file-name-nondirectory buffer-file-name)))
        (xref-go-back)
        (should (equal "Ongoing work.md"
                       (file-name-nondirectory buffer-file-name)))
        (should (= origin (point)))))))

(ert-deftest pumice-test-follow-to-heading ()
  (pumice-test-with-vault
    (save-window-excursion
      (with-temp-buffer
        (pumice-open v "Weekly Review" "checklist")
        (should (looking-at-p "## Checklist"))))))

(ert-deftest pumice-test-missing-attachment-is-not-a-new-note ()
  (pumice-test-with-vault
    (should-error (pumice-open v "gone.png") :type 'user-error)))

(ert-deftest pumice-test-toggle-checkbox ()
  (pumice-test-with-vault
    (pumice-test-in-note "Weekly Review.md"
      (search-forward "Empty the inbox")
      (should (pumice-follow))
      (should (looking-back "- \\[x\\] Empty the inbox" (pos-bol)))
      (should (pumice-toggle-checkbox))
      (should (looking-back "- \\[ \\] Empty the inbox" (pos-bol))))))

(ert-deftest pumice-test-link-text ()
  (pumice-test-with-vault
    (let ((review (pumice-test--note v "Weekly Review.md"))
          (clojure (pumice-test--note v "Notes/Work/Clojure.md")))
      (pumice-test-in-note "Home.md"
        (should (equal "[[Weekly Review]]"
                       (pumice--link-text v (cons review nil))))
        (should (equal "[[Weekly Review|Review]]"
                       (pumice--link-text v (cons review "Review"))))
        (should (equal "[[Weekly Review|the ritual]]"
                       (pumice--link-text v (cons review nil) "the ritual")))
        (should (equal "[[Notes/Work/Clojure]]"
                       (pumice--link-text v (cons clojure nil))))
        (should (equal "[[Brand new]]" (pumice--link-text v "Brand new")))))))

(ert-deftest pumice-test-next-link ()
  (pumice-test-with-vault
    (pumice-test-in-note "Home.md"
      (pumice-next-link)
      (should (looking-at-p "\\[\\[Weekly Review"))
      (pumice-next-link)
      (should (looking-at-p "\\[\\[Ongoing work"))
      (pumice-next-link)
      (should (looking-at-p "!\\[\\[Follow-ups"))
      (pumice-next-link)
      (should (looking-at-p "\\[\\[Notes/Work"))
      (pumice-previous-link 2)
      (should (looking-at-p "\\[\\[Ongoing work")))))

;;; Templates, daily notes, capture

(ert-deftest pumice-test-expand-template ()
  (let ((time (encode-time '(0 5 9 7 8 2026 nil -1 nil))))
    (should (equal "T 2026-08-07 09:05 Aug 7"
                   (pumice--expand-template
                    "{{title}} {{date}} {{time}} {{date:MMM D}}" "T" time)))))

(ert-deftest pumice-test-daily-note-from-template ()
  (pumice-test-with-vault
    (let ((time (encode-time '(0 0 12 9 11 2026 nil -1 nil))))
      (with-current-buffer (pumice--daily-buffer v time)
        (should (equal (expand-file-name "Day Notes/2026/11/Nov 9, 2026.md" root)
                       buffer-file-name))
        (should (equal "## Log\n\nNov 9, 2026 on 2026-11-09\n" (buffer-string)))))
    ;; Asking twice for a note that is not on disk yet returns the same
    ;; buffer, without a prompt about the missing folder.
    (let ((time (encode-time '(0 0 12 10 11 2026 nil -1 nil))))
      (should (eq (pumice--daily-buffer v time) (pumice--daily-buffer v time)))
      (should-not (buffer-local-value 'buffer-read-only
                                      (pumice--daily-buffer v time))))
    ;; An existing daily note is left as it is.
    (with-current-buffer
        (pumice--daily-buffer v (encode-time '(0 0 12 14 8 2026 nil -1 nil)))
      (should (equal "## Log\n" (buffer-string))))))

(ert-deftest pumice-test-daily-step ()
  (pumice-test-with-vault
    (cl-letf (((symbol-function 'pumice--now)
               (lambda () (encode-time '(0 0 12 9 11 2026 nil -1 nil)))))
      (should (equal '("Aug 7, 2026" "Aug 14, 2026")
                     (mapcar (lambda (entry) (file-name-base (cdr entry)))
                             (pumice--daily-notes v))))
      (save-window-excursion
        (pumice-test-in-note "Day Notes/2026/08/Aug 14, 2026.md"
          (pumice-daily-previous)
          (should (equal "Aug 7, 2026" (file-name-base buffer-file-name)))
          (pumice-daily-next)
          (should (equal "Aug 14, 2026" (file-name-base buffer-file-name)))
          (should-error (pumice-daily-next) :type 'user-error))))))

(ert-deftest pumice-test-log ()
  (pumice-test-with-vault
    (cl-letf (((symbol-function 'pumice--now)
               (lambda () (encode-time '(0 30 8 14 8 2026 nil -1 nil)))))
      (let ((rel "Day Notes/2026/08/Aug 14, 2026.md"))
        (pumice-log "first")
        (should (equal "## Log\n\n- 08:30 first\n" (pumice-test--read v rel)))
        (pumice-log "second")
        (should (equal "## Log\n\n- 08:30 first\n- 08:30 second\n"
                       (pumice-test--read v rel)))
        ;; Entries stay inside the log section when another one follows.
        (write-region "## Log\n\n## Follow up\n\ntail\n" nil
                      (expand-file-name rel root))
        (with-current-buffer (find-buffer-visiting (expand-file-name rel root))
          (revert-buffer t t))
        (pumice-log "third")
        (should (equal "## Log\n\n- 08:30 third\n\n## Follow up\n\ntail\n"
                       (pumice-test--read v rel)))))))

(ert-deftest pumice-test-capture-path ()
  (pumice-test-with-vault
    (should (equal (expand-file-name "Inbox/Idea.md" root)
                   (pumice--new-note-path v "Idea")))
    (should (equal (expand-file-name "Projects/Idea.md" root)
                   (pumice--new-note-path v "Projects/Idea.md")))))

(ert-deftest pumice-test-tags ()
  (pumice-test-with-vault
    (let ((tags (pumice-tags v)))
      (should (equal '("gtd" "routine" "work" "work/project")
                     (mapcar #'car tags)))
      (should (equal '("Home" "Weekly Review")
                     (sort (mapcar #'pumice-note-name (cdr (assoc "gtd" tags)))
                           #'string<))))))

(ert-deftest pumice-test-search-without-consult ()
  "Search falls back to rgrep over the vault's Markdown files."
  (skip-unless (not (locate-library "consult")))
  ;; Loaded now, or loading it inside the command would undo the stub.
  (require 'grep)
  (pumice-test-with-vault
    (let (called)
      (cl-letf (((symbol-function 'read-regexp) (lambda (&rest _) "inbox"))
                ((symbol-function 'rgrep) (lambda (&rest args)
                                            (setq called args))))
        (pumice-search))
      (should (equal (list "inbox" "*.md" root) called)))))

;;; Renaming

(ert-deftest pumice-test-rename-rewrites-links ()
  (pumice-test-with-vault
    (let ((count (pumice-rename-note v (pumice-test--note v "Weekly Review.md")
                                     "Routines/Review ritual")))
      (should (= 2 count))
      (should (file-exists-p (expand-file-name "Routines/Review ritual.md" root)))
      (should-not (file-exists-p (expand-file-name "Weekly Review.md" root)))
      (should (string-search "[[Review ritual]] and [[Ongoing work|Projects]]"
                             (pumice-test--read v "Home.md")))
      (should (string-search "[the review](Routines/Review%20ritual.md)"
                             (pumice-test--read v "Ongoing work.md")))
      ;; Everything that pointed at the note still does.
      (should (= 2 (length (pumice-backlinks
                            v (pumice-test--note v "Routines/Review ritual.md"))))))))

(ert-deftest pumice-test-rename-keeps-path-links-and-suffixes ()
  (pumice-test-with-vault
    (pumice-rename-note v (pumice-test--note v "Notes/Work/Trellis.md")
                        "Notes/Work/Lattice")
    (should (string-search "[[Notes/Work/Lattice]] #gtd"
                           (pumice-test--read v "Home.md")))
    (pumice-rename-note v (pumice-test--note v "Home.md") "Start")
    (should (string-search "See [[Start#Goals]]"
                           (pumice-test--read v "Ongoing work.md")))))

(ert-deftest pumice-test-rename-into-a-shared-name-uses-paths ()
  (pumice-test-with-vault
    (pumice-rename-note v (pumice-test--note v "Weekly Review.md") "Clojure")
    (should (string-search "[[Clojure]] and" (pumice-test--read v "Home.md")))
    ;; From Home, [[Clojure]] must now mean the new root-level note.
    (should (equal "Clojure"
                   (pumice-note-rel
                    (pumice-resolve v "Clojure"
                                    (pumice-test--note v "Home.md")))))))

(ert-deftest pumice-test-rename-moves-visiting-buffers ()
  (pumice-test-with-vault
    (let ((home (find-file-noselect (expand-file-name "Home.md" root)))
          (review (find-file-noselect (expand-file-name "Weekly Review.md" root))))
      (with-current-buffer home
        (goto-char (point-max))
        (insert "unsaved\n"))
      (pumice-rename-note v (pumice-test--note v "Weekly Review.md") "Review")
      (should (equal (expand-file-name "Review.md" root)
                     (buffer-file-name review)))
      ;; Home had unsaved edits, so it is updated but not written.
      (with-current-buffer home
        (should (buffer-modified-p))
        (should (string-search "[[Review]]" (buffer-string))))
      (should (string-search "[[Weekly Review]]"
                             (pumice-test--read v "Home.md"))))))

(ert-deftest pumice-test-rename-refuses-to-overwrite ()
  (pumice-test-with-vault
    (should-error (pumice-rename-note v (pumice-test--note v "Home.md")
                                      "Ongoing work")
                  :type 'user-error)
    (should (file-exists-p (expand-file-name "Home.md" root)))))

(ert-deftest pumice-test-extract ()
  (pumice-test-with-vault
    (pumice-test-in-note "Notes/Clojure.md"
      (pumice-extract "Aside" (progn (search-forward "Mentions") (match-beginning 0))
                      (point-max))
      (should (equal "The general one. [[Aside]]" (buffer-string))))
    (should (equal "Mentions Trellis in passing.\n"
                   (pumice-test--read v "Inbox/Aside.md")))))

;;; Note buffers

(ert-deftest pumice-test-mode-turns-on-only-in-vaults ()
  (pumice-test-with-vault
    (pumice-test-in-note "Home.md"
      (should pumice-mode))
    (pumice-test-in-note "Follow-ups.base"
      (should-not pumice-mode)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/elsewhere/README.md")
    (let ((pumice-vault-directories (list "/nonexistent-vault/")))
      (pumice-mode-maybe))
    (should-not pumice-mode)
    (setq buffer-file-name nil)))

(ert-deftest pumice-test-link-faces ()
  (pumice-test-with-vault
    (pumice-test-in-note "Home.md"
      (font-lock-mode 1)
      (font-lock-ensure)
      (cl-flet ((face-at (text)
                  (goto-char (point-min))
                  (search-forward text)
                  (get-text-property (match-beginning 0) 'face)))
        (should (eq 'pumice-link (face-at "Weekly Review")))
        (should (eq 'pumice-link-unresolved (face-at "Nowhere")))
        ;; With an alias the alias is the link and the target recedes.
        (should (eq 'pumice-markup (face-at "Ongoing work")))
        (should (eq 'pumice-link (face-at "Projects")))
        (should (eq 'pumice-link (face-at "Follow-ups.base")))
        (should (eq 'pumice-tag (face-at "#gtd")))))))

(ert-deftest pumice-test-opening-a-note-indexes-its-vault ()
  "A note opened before anything has scanned the vault still sees its links."
  (pumice-test-with-vault
    (clrhash pumice--cache)
    (pumice-test-in-note "Home.md"
      (font-lock-mode 1)
      (font-lock-ensure)
      (search-forward "Weekly Review")
      (should (eq 'pumice-link (get-text-property (match-beginning 0) 'face)))
      (should (member "Weekly Review"
                      (cdr (pumice-test--complete "\n[[Week")))))))

(defun pumice-test--complete (text)
  "Insert TEXT at the end of the buffer and return (PREFIX . CANDIDATES)."
  (goto-char (point-max))
  (insert text)
  (pcase-let ((`(,beg ,end ,table . ,_) (pumice-completion-at-point)))
    (and beg (cons (buffer-substring beg end)
                   (all-completions "" table)))))

(ert-deftest pumice-test-completion ()
  (pumice-test-with-vault
    (pumice-test-in-note "Home.md"
      (should-not (pumice-test--complete "plain text"))
      ;; Notes are offered straight after [[, whatever prefix length the
      ;; completion popup otherwise waits for.
      (insert "\n[[")
      (should (eq t (plist-get (nthcdr 3 (pumice-completion-at-point))
                               :company-prefix-length)))
      (pcase-let ((`(,prefix . ,names) (pumice-test--complete "\n[[Week")))
        (should (equal "Week" prefix))
        (should (member "Weekly Review" names))
        (should (member "Weekly Review|Review" names))
        ;; Of two notes called Clojure, the one a bare [[Clojure]] reaches
        ;; from here keeps the short name and the other is offered by path.
        (should (member "Clojure" names))
        (should (member "Notes/Work/Clojure" names)))
      (should (equal '("Che" "Checklist")
                     (pumice-test--complete "\n[[Weekly Review#Che")))
      (pcase-let ((`(,prefix . ,tags) (pumice-test--complete "\n#wo")))
        (should (equal "wo" prefix))
        (should (member "work/project" tags)))
      (set-buffer-modified-p nil))))

;;; Mentions and the panel

(ert-deftest pumice-test-unlinked-mentions ()
  (skip-unless (executable-find "rg"))
  (pumice-test-with-vault
    (let* ((trellis (pumice-test--note v "Notes/Work/Trellis.md"))
           (mentions (pumice-unlinked-mentions v trellis)))
      ;; Home links to it, so only the plain mention counts.
      (should (equal (list (list (expand-file-name "Notes/Clojure.md" root) 1
                                 "The general one. Mentions Trellis in passing."))
                     mentions))
      (should (pumice-link-mention (expand-file-name "Notes/Clojure.md" root)
                                   1 trellis))
      (should (equal "The general one. Mentions [[Trellis]] in passing.\n"
                     (pumice-test--read v "Notes/Clojure.md")))
      (should-not (pumice-unlinked-mentions v trellis))
      ;; Home, the property in Work/Clojure, and now Notes/Clojure.
      (should (= 3 (length (pumice-backlinks v trellis)))))))

(ert-deftest pumice-test-panel ()
  (pumice-test-with-vault
    (save-window-excursion
      (find-file (expand-file-name "Home.md" root))
      (delete-other-windows)
      (pumice-panel-toggle)
      (unwind-protect
          (with-current-buffer pumice-panel-buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-prefix-p "Home\n" text))
              (should (string-search "Backlinks  3" text))
              (should (string-search "    Back to [[Home]]." text))
              (should (string-search "Links  5" text))
              (should (string-search "  Nowhere\n" text)))
            ;; RET on a context line lands on that line of the source.
            (select-window (get-buffer-window pumice-panel-buffer))
            (goto-char (point-min))
            (search-forward "Back to")
            (pumice-panel-visit)
            (should (equal "Weekly Review.md"
                           (file-name-nondirectory buffer-file-name)))
            (should (looking-at-p "Back to \\[\\[Home\\]\\]"))
            ;; The panel follows the note that is now selected.
            (pumice-panel--sync)
            (with-current-buffer pumice-panel-buffer
              (should (string-prefix-p "Weekly Review\n" (buffer-string)))
              (should (string-search "Backlinks  2" (buffer-string)))))
        (when (get-buffer-window pumice-panel-buffer) (pumice-panel-toggle))
        (kill-buffer pumice-panel-buffer)))))

;;; Folder tree

(defmacro pumice-test-with-tree (rel &rest body)
  "Run BODY in the folder tree, opened from the note at REL."
  (declare (indent 1) (debug t))
  `(pumice-test-with-vault
     (save-window-excursion
       (find-file (expand-file-name ,rel root))
       (delete-other-windows)
       (pumice-tree)
       (unwind-protect
           (progn ,@body)
         (when (get-buffer pumice-tree-buffer)
           (kill-buffer pumice-tree-buffer))))))

(ert-deftest pumice-test-tree-lists-folders-first ()
  (pumice-test-with-tree "Home.md"
    (should (equal (concat "▸ Attachments\n▸ Day Notes  2\n▸ Notes  3\n"
                           "▸ Templates  1\n  Home\n  Ongoing work\n"
                           "  Weekly Review\n  Follow-ups.base\n")
                   (buffer-substring-no-properties (point-min) (point-max))))
    ;; Opened from Home, so point is there and it is marked as current.
    (should (looking-at-p "  Home$"))
    (should (eq 'pumice-tree-current (get-text-property (+ (point) 2) 'face)))
    ;; Commands run from the tree act on the vault it shows.
    (should (eq v (pumice-current-vault)))))

(ert-deftest pumice-test-tree-follows-the-current-note ()
  (pumice-test-with-tree "Home.md"
    (select-window (get-mru-window nil nil t))
    (find-file (expand-file-name "Notes/Work/Trellis.md" root))
    (pumice-tree--sync)
    (with-selected-window (get-buffer-window pumice-tree-buffer)
      (should (string-search
               (concat "▾ Notes  3\n  ▾ Work  2\n      Clojure\n"
                       "      Trellis\n    Clojure\n")
               (buffer-substring-no-properties (point-min) (point-max))))
      (should (looking-at-p "      Trellis$")))))

(ert-deftest pumice-test-tree-steps-in-and-out ()
  (pumice-test-with-tree "Notes/Work/Trellis.md"
    (should (looking-at-p "      Trellis$"))
    (pumice-tree-collapse)
    (should (looking-at-p "  ▾ Work"))
    (pumice-tree-collapse)
    (should (looking-at-p "  ▸ Work"))
    (should-not (string-search "Trellis" (buffer-string)))
    (pumice-tree-expand)
    (should (looking-at-p "  ▾ Work"))
    (pumice-tree-expand)
    (should (looking-at-p "      Clojure$"))
    (pumice-tree-collapse-all)
    (should (looking-at-p "▸ Notes"))
    (pumice-tree-expand-all)
    ;; Version order: the 7th sorts before the 14th.
    (should (string-search
             "    ▾ 08  2\n        Aug 7, 2026\n        Aug 14, 2026\n"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest pumice-test-tree-opens-notes ()
  (pumice-test-with-tree "Home.md"
    (let ((tree (selected-window)))
      (pumice-tree--goto (expand-file-name "Weekly Review.md" root))
      (pumice-tree-peek)
      (should (eq tree (selected-window)))
      (should (equal "Weekly Review.md"
                     (file-name-nondirectory
                      (buffer-file-name
                       (window-buffer (get-mru-window nil nil t))))))
      (should (looking-at-p "  Weekly Review$"))
      (should (eq 'pumice-tree-current
                  (get-text-property (+ (point) 2) 'face)))
      (pumice-tree--goto (expand-file-name "Ongoing work.md" root))
      (pumice-tree-visit)
      (should-not (eq tree (selected-window)))
      (should (equal "Ongoing work.md"
                     (file-name-nondirectory buffer-file-name))))))

(ert-deftest pumice-test-tree-new-note ()
  (pumice-test-with-tree "Home.md"
    ;; On a note the folder is the one holding it; on a folder, itself.
    (should (equal (directory-file-name root) (pumice-tree--folder)))
    (pumice-tree--goto (expand-file-name "Notes" root))
    (should (equal (expand-file-name "Notes" root) (pumice-tree--folder)))
    (pumice-tree-new-note (pumice-tree--folder) "Idea")
    (should (equal (expand-file-name "Notes/Idea.md" root) buffer-file-name))
    (should-not (file-exists-p buffer-file-name))
    (should-not buffer-read-only)))

(ert-deftest pumice-test-tree-rename ()
  (pumice-test-with-tree "Home.md"
    (pumice-tree-rename (expand-file-name "Weekly Review.md" root)
                        "Notes/Review")
    (should (file-exists-p (expand-file-name "Notes/Review.md" root)))
    (should (string-search "[[Review]]" (pumice-test--read v "Home.md")))
    ;; The tree unfolds the new folder and lands on the note.
    (should (looking-at-p "    Review$"))
    (should (string-search "▾ Notes  4\n" (buffer-string)))))

(ert-deftest pumice-test-tree-sorts-by-change ()
  (pumice-test-with-tree "Home.md"
    (pcase-dolist (`(,rel . ,age) '(("Weekly Review.md" . 60)
                                    ("Ongoing work.md" . 120)
                                    ("Home.md" . 180)))
      (set-file-times (expand-file-name rel root) (time-subtract nil age)))
    (pumice-tree-refresh)
    (should (string-search "  Home\n  Ongoing work\n  Weekly Review\n"
                           (buffer-string)))
    (pumice-tree-sort)
    (should (string-search "  Weekly Review\n  Ongoing work\n  Home\n"
                           (buffer-string)))
    (should (string-search "by date" header-line-format))))

(ert-deftest pumice-test-side-windows-open-things-in-the-main-window ()
  (pumice-test-with-tree "Home.md"
    (let ((tree (selected-window)))
      (find-file (expand-file-name "Weekly Review.md" root))
      (should-not (eq tree (selected-window)))
      (should (equal "Weekly Review.md"
                     (file-name-nondirectory buffer-file-name)))
      (select-window tree)
      (switch-to-buffer
       (find-file-noselect (expand-file-name "Ongoing work.md" root)))
      (should-not (eq tree (selected-window)))
      (should (equal "Ongoing work.md"
                     (file-name-nondirectory buffer-file-name)))
      ;; Neither split the main window nor took over the tree's.
      (should (= 2 (count-windows)))
      (should (eq (get-buffer pumice-tree-buffer) (window-buffer tree))))))

(ert-deftest pumice-test-panel-keeps-up-from-the-tree ()
  "A rename made from the tree reaches the panel without leaving the tree."
  (pumice-test-with-tree "Home.md"
    (pumice-panel-toggle)
    (unwind-protect
        (progn
          (should (eq (selected-window) (get-buffer-window pumice-tree-buffer)))
          (with-current-buffer pumice-panel-buffer
            (should (string-prefix-p "Home\n" (buffer-string)))
            (should (string-search "  Weekly Review\n" (buffer-string))))
          (pumice-tree-rename (expand-file-name "Weekly Review.md" root)
                              "Review week")
          (pumice-panel--sync)
          (with-current-buffer pumice-panel-buffer
            (should (string-search "  Review week\n" (buffer-string)))
            (should-not (string-search "Weekly Review" (buffer-string)))))
      (when (get-buffer-window pumice-panel-buffer) (pumice-panel-toggle))
      (kill-buffer pumice-panel-buffer))))

(ert-deftest pumice-test-tree-opened-from-the-panel-finds-the-note ()
  "Opened while the panel is selected, the tree still goes to the note."
  (pumice-test-with-vault
    (save-window-excursion
      (find-file (expand-file-name "Notes/Work/Trellis.md" root))
      (delete-other-windows)
      (pumice-panel-focus)
      (unwind-protect
          (progn
            (pumice-tree)
            (should (eq (selected-window)
                        (get-buffer-window pumice-tree-buffer)))
            (should (looking-at-p "      Trellis$")))
        (when (get-buffer pumice-tree-buffer) (kill-buffer pumice-tree-buffer))
        (when (get-buffer-window pumice-panel-buffer) (pumice-panel-toggle))
        (kill-buffer pumice-panel-buffer)))))

;;; Evil

(declare-function evil-local-mode "evil-core")
(declare-function evil-normal-state "evil-states")
(declare-function evil-initial-state "evil-core")
(declare-function evil-get-auxiliary-keymap "evil-core")
(declare-function pumice-evil-ret "pumice-evil")

(ert-deftest pumice-test-evil-keys ()
  "The optional vim keys exist in notes, the panel and the tree."
  (skip-unless (locate-library "evil"))
  ;; Before evil, to show the order does not matter.
  (require 'pumice-evil)
  (require 'evil)
  (pumice-test-with-vault
    (pumice-test-in-note "Home.md"
      (evil-local-mode 1)
      (evil-normal-state)
      (should (eq 'pumice-evil-ret (key-binding (kbd "RET"))))
      (should (eq 'pumice-follow (key-binding "gf")))
      (should (eq 'pumice-daily-next (key-binding "]d")))
      ;; RET follows a link, and off one it is still evil's RET.
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (goto-char (point-min))
        (should (= 2 (progn (pumice-evil-ret 1) (line-number-at-pos))))
        (search-forward "[[Weekly")
        (pumice-evil-ret)
        (should (equal "Weekly Review.md"
                       (file-name-nondirectory buffer-file-name)))))
    (should (eq 'motion (evil-initial-state 'pumice-tree-mode)))
    (should (eq 'motion (evil-initial-state 'pumice-panel-mode)))
    (should (eq 'pumice-tree-expand
                (lookup-key (evil-get-auxiliary-keymap
                             pumice-tree-mode-map 'motion)
                            "l")))
    (should (eq 'pumice-panel-link-mention
                (lookup-key (evil-get-auxiliary-keymap
                             pumice-panel-mode-map 'motion)
                            "L")))))

;;; Properties

(ert-deftest pumice-test-frontmatter-properties ()
  (pumice-test-with-vault
    (should (equal '(("aliases" "Review" "Weekly") ("tags" "gtd" "routine"))
                   (pumice-note-props (pumice-test--note v "Weekly Review.md"))))
    (should (equal '(("parent" . "[[Trellis]]") ("colour" . "#fff"))
                   (pumice-note-props
                    (pumice-test--note v "Notes/Work/Clojure.md"))))
    (should-not (pumice-note-props (pumice-test--note v "Home.md")))))

(defun pumice-test--set-property (text key value)
  "Return TEXT after setting its frontmatter property KEY to VALUE."
  (with-temp-buffer
    (insert text)
    (pumice-set-property key value)
    (buffer-string)))

(ert-deftest pumice-test-set-property ()
  ;; A note without frontmatter gets some.
  (should (equal "---\nstatus: done\n---\nBody\n"
                 (pumice-test--set-property "Body\n" "status" "done")))
  ;; A new key goes last; an existing one is replaced where it stands.
  (should (equal "---\na: 1\nb: 2\n---\n"
                 (pumice-test--set-property "---\na: 1\n---\n" "b" "2")))
  (should (equal "---\na: 9\nb: 2\n---\n"
                 (pumice-test--set-property "---\na: 1\nb: 2\n---\n" "a" "9")))
  ;; A list is replaced along with its items, and can be written.
  (should (equal "---\ntags: x\nb: 2\n---\n"
                 (pumice-test--set-property
                  "---\ntags:\n  - one\n  - two\nb: 2\n---\n" "tags" "x")))
  (should (equal "---\ntags:\n  - one\n  - two\n---\n"
                 (pumice-test--set-property "---\ntags: x\n---\n" "tags"
                                            '("one" "two"))))
  ;; Removing a key takes its items with it and leaves the body alone.
  (should (equal "---\nb: 2\n---\ntags: body\n"
                 (pumice-test--set-property
                  "---\ntags:\n  - one\nb: 2\n---\ntags: body\n" "tags" nil)))
  ;; Values YAML would misread are quoted.
  (should (equal "---\nparent: \"[[Home]]\"\n---\n"
                 (pumice-test--set-property "---\n---\n" "parent" "[[Home]]")))
  (should (equal "---\nnext: \"Call: the \\\"bank\\\"\"\n---\n"
                 (pumice-test--set-property "---\n---\n" "next"
                                            "Call: the \"bank\"")))
  (should (equal "---\nnext: \"\"\n---\n"
                 (pumice-test--set-property "---\n---\n" "next" "")))
  (should (equal "---\ndone: true\n---\n"
                 (pumice-test--set-property "---\n---\n" "done" "true")))
  ;; What is written reads back as what was meant.
  (with-temp-buffer
    (insert "Body\n")
    (should (pumice-set-property "next" "Call: the \"bank\" #1"))
    (should (equal '(("next" . "Call: the \"bank\" #1")) (pumice--frontmatter)))
    (should-not (pumice-set-property "next" "Call: the \"bank\" #1"))))

;;; Command line

(defun pumice-test--cli (&rest args)
  "Run the command line ARGS in the fixture vault; return its output."
  (let ((process-environment (cons "PUMICE_VAULT" process-environment))
        (default-directory temporary-file-directory))
    (with-output-to-string (pumice-cli-run args))))

(defun pumice-test--cli-lines (&rest args)
  "Run the command line ARGS and return its output lines, sorted."
  (sort (split-string (apply #'pumice-test--cli args) "\n" t) #'string<))

(defmacro pumice-test-at (time &rest body)
  "Run BODY with the clock stopped at TIME, a list for `encode-time'."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'pumice--now)
              (lambda () (encode-time ',time))))
     ,@body))

(ert-deftest pumice-test-cli-list ()
  (pumice-test-with-vault
    (should (equal '("Home.md" "Weekly Review.md")
                   (pumice-test--cli-lines "list" "--tag" "gtd")))
    (should (equal '("Notes/Work/Trellis.md")
                   (pumice-test--cli-lines "list" "--tag" "#work")))
    (should (equal '("Notes/Clojure.md" "Notes/Work/Clojure.md"
                     "Notes/Work/Trellis.md")
                   (pumice-test--cli-lines "list" "--folder" "Notes/")))
    ;; Templates are left out unless asked for.
    (should (= 8 (length (pumice-test--cli-lines "list"))))
    (should (member "Templates/Day note.md"
                    (pumice-test--cli-lines "list" "--templates")))
    (should (= 2 (length (pumice-test--cli-lines "list" "--limit" "2"))))
    (should (equal (list (expand-file-name "Notes/Clojure.md" root)
                         (expand-file-name "Notes/Work/Trellis.md" root))
                   (pumice-test--cli-lines "list" "--abs" "--folder" "Notes"
                                           "--where" "!parent"
                                           "--where" "!tags")))))

(ert-deftest pumice-test-cli-where ()
  (pumice-test-with-vault
    (should (equal '("Notes/Work/Clojure.md")
                   (pumice-test--cli-lines "list" "--where" "colour=#fff")))
    (should (equal '("Notes/Work/Clojure.md")
                   (pumice-test--cli-lines "list" "--where" "colour == \"#fff\"")))
    (should (equal '("Notes/Work/Clojure.md")
                   (pumice-test--cli-lines "list" "--where" "parent")))
    ;; A list property matches on any of its items.
    (should (equal '("Weekly Review.md")
                   (pumice-test--cli-lines "list" "--where" "tags=routine")))
    (should (equal '("Notes/Work/Trellis.md")
                   (pumice-test--cli-lines "list" "--folder" "Notes/Work"
                                           "--where" "colour!=#fff")))
    (should (equal "Notes/Work/Clojure.md\t#fff\t[[Trellis]]\t\n"
                   (pumice-test--cli "list" "--where" "colour"
                                     "--show" "colour, parent,tags")))
    (should (equal "Weekly Review.md\tgtd, routine\n"
                   (pumice-test--cli "list" "--where" "aliases=Review"
                                     "--show" "tags")))))

(ert-deftest pumice-test-cli-json ()
  (pumice-test-with-vault
    (let ((notes (json-parse-string
                  (pumice-test--cli "list" "--json" "--where" "colour")
                  :object-type 'alist)))
      (should (= 1 (length notes)))
      (let-alist (aref notes 0)
        (should (equal "Notes/Work/Clojure.md" .path))
        (should (equal "#fff" .properties.colour))
        (should (equal [] .tags))))
    (let-alist (json-parse-string (pumice-test--cli "info" "--json" "Weekly Review")
                                  :object-type 'alist)
      (should (equal ["Review" "Weekly"] .aliases))
      (should (equal ["gtd" "routine"] .properties.tags))
      (should (= 1 .links))
      (should (= 2 .backlinks)))
    ;; Nothing found is still an array.
    (should (equal "[]\n" (pumice-test--cli "list" "--json" "--tag" "none")))))

(ert-deftest pumice-test-cli-find-notes ()
  (pumice-test-with-vault
    (let ((review (concat (expand-file-name "Weekly Review.md" root) "\n")))
      (should (equal review (pumice-test--cli "path" "Weekly Review")))
      (should (equal review (pumice-test--cli "path" "weekly review.md")))
      ;; An alias, a file path, and a path from the root all work.
      (should (equal review (pumice-test--cli "path" "Review")))
      (should (equal review (pumice-test--cli "path" (string-trim review))))
      (should (equal (concat (expand-file-name "Notes/Work/Clojure.md" root) "\n")
                     (pumice-test--cli "path" "Notes/Work/Clojure.md"))))
    (should (equal (concat (expand-file-name "Attachments/diagram.png" root) "\n")
                   (pumice-test--cli "path" "diagram.png")))
    (should (equal (pumice-test--read v "Home.md") (pumice-test--cli "read" "home")))
    (let ((err (should-error (pumice-test--cli "path" "Trel") :type 'user-error)))
      (should (string-search "Close: Notes/Work/Trellis" (cadr err))))
    (should (string-search "aliases: Review, Weekly\ntags: gtd, routine\n"
                           (pumice-test--cli "info" "Weekly Review")))))

(ert-deftest pumice-test-cli-links ()
  (pumice-test-with-vault
    (should (equal (concat "3: [[Weekly Review]] -> Weekly Review.md\n"
                           "3: [[Ongoing work]] -> Ongoing work.md\n"
                           "4: [[Follow-ups.base#Active]] -> Follow-ups.base\n"
                           "5: [[Notes/Work/Trellis]] -> Notes/Work/Trellis.md\n"
                           "6: [[Nowhere]] -> (no such note)\n")
                   (pumice-test--cli "links" "Home")))
    (should (equal '("Day Notes/2026/08/Aug 7, 2026.md:3: [[Home]]"
                     "Ongoing work.md:1: See [[Home#Goals]] and [the review](Weekly%20Review.md)."
                     "Weekly Review.md:7: Back to [[Home]].")
                   (pumice-test--cli-lines "backlinks" "Home")))
    (should (equal "Home.md:6: [[Nowhere]]\n" (pumice-test--cli "unresolved")))
    (should (equal '("Day Notes/2026/08/Aug 14, 2026.md"
                     "Day Notes/2026/08/Aug 7, 2026.md" "Notes/Clojure.md")
                   (pumice-test--cli-lines "orphans")))
    (should (equal '("Notes/Clojure.md")
                   (pumice-test--cli-lines "orphans" "--folder" "Notes")))
    (should (equal '("Day Notes/2026/08/Aug 14, 2026.md" "Notes/Clojure.md")
                   (pumice-test--cli-lines "deadends")))
    (should (equal '("gtd\t2" "routine\t1" "work\t1" "work/project\t1")
                   (pumice-test--cli-lines "tags")))))

(ert-deftest pumice-test-cli-tasks ()
  (pumice-test-with-vault
    (make-directory (expand-file-name "Inbox" root))
    (write-region (concat "- [x] Done\n\n```\n- [ ] In a code block\n```\n"
                          "1. [ ] Numbered\n  * [/] Half done\n")
                  nil (expand-file-name "Inbox/Chores.md" root) nil 'silent)
    (should (equal '("Inbox/Chores.md:6: [ ] Numbered"
                     "Weekly Review.md:11: [ ] Empty the inbox")
                   (pumice-test--cli-lines "tasks")))
    (should (equal "Inbox/Chores.md:1: [x] Done\nInbox/Chores.md:7: [x] Half done\n"
                   (pumice-test--cli "tasks" "--done")))
    (should (equal 3 (length (pumice-test--cli-lines "tasks" "Chores" "--all"))))
    (should (equal "Weekly Review.md:11: [ ] Empty the inbox\n"
                   (pumice-test--cli "tasks" "--tag" "routine")))))

(ert-deftest pumice-test-cli-daily ()
  (pumice-test-with-vault
    (pumice-test-at (0 30 8 14 8 2026 nil -1 nil)
      (let ((today (expand-file-name "Day Notes/2026/08/Aug 14, 2026.md" root))
            (tomorrow (expand-file-name "Day Notes/2026/08/Aug 15, 2026.md" root)))
        (should (equal (concat today "\n") (pumice-test--cli "daily")))
        (should (equal "## Log\n" (pumice-test--cli "daily" "today" "--read")))
        (should (equal "## Log\n\n[[Home]]\n"
                       (pumice-test--cli "daily" "-7" "--read")))
        (should (equal "## Log\n\n[[Home]]\n"
                       (pumice-test--cli "daily" "2026-08-07" "--read")))
        ;; --path and --read create nothing; plain `daily' does.
        (should (equal (concat tomorrow "\n")
                       (pumice-test--cli "daily" "tomorrow" "--path")))
        (should-error (pumice-test--cli "daily" "+1" "--read") :type 'user-error)
        (should-not (file-exists-p tomorrow))
        (should (equal (concat tomorrow "\n") (pumice-test--cli "daily" "tomorrow")))
        (should (equal "## Log\n\nAug 15, 2026 on 2026-08-15\n"
                       (pumice-test--read v "Day Notes/2026/08/Aug 15, 2026.md")))
        (should-error (pumice-test--cli "daily" "someday")
                      :type 'pumice-cli-usage)))))

(ert-deftest pumice-test-cli-log ()
  (pumice-test-with-vault
    (pumice-test-at (0 30 8 14 8 2026 nil -1 nil)
      (pumice-test--cli "log" "from" "an agent")
      (should (equal "## Log\n\n- 08:30 from an agent\n"
                     (pumice-test--read v "Day Notes/2026/08/Aug 14, 2026.md"))))
    ;; A day with no note yet gets one from the template first.
    (pumice-test-at (0 5 9 16 8 2026 nil -1 nil)
      (pumice-test--cli "log" "new day")
      (should (equal "## Log\n\nAug 16, 2026 on 2026-08-16\n- 09:05 new day\n"
                     (pumice-test--read v "Day Notes/2026/08/Aug 16, 2026.md"))))))

(ert-deftest pumice-test-cli-new ()
  (pumice-test-with-vault
    (pumice-test-at (0 30 8 14 8 2026 nil -1 nil)
      (should (equal (concat (expand-file-name "Inbox/Idea.md" root) "\n")
                     (pumice-test--cli "new" "Idea")))
      (should (equal "" (pumice-test--read v "Inbox/Idea.md")))
      (should-error (pumice-test--cli "new" "Idea") :type 'user-error)
      (cl-letf (((symbol-function 'pumice-cli--stdin) (lambda () "From stdin\n")))
        (pumice-test--cli "new" "Standup" "--folder" "Notes/Work" "--stdin"
                          "--template" "day note"))
      (should (equal "## Log\n\nStandup on 2026-08-14\nFrom stdin\n"
                     (pumice-test--read v "Notes/Work/Standup.md")))
      (should-error (pumice-test--cli "new" "X" "--template" "Missing")
                    :type 'user-error)
      (should-error (pumice-test--cli "new" "../../escape") :type 'user-error))))

(ert-deftest pumice-test-cli-set ()
  (pumice-test-with-vault
    (pumice-test--cli "set" "Home" "followup=active" "next_action=Call: the bank")
    (should (string-prefix-p
             "---\nfollowup: active\nnext_action: \"Call: the bank\"\n---\n# Home\n"
             (pumice-test--read v "Home.md")))
    (should (equal "Home.md\tCall: the bank\n"
                   (pumice-test--cli "list" "--where" "followup=active"
                                     "--show" "next_action")))
    (pumice-test--cli "set" "Home" "followup=done")
    (should-not (pumice-test--cli-lines "list" "--where" "followup=active"))
    (pumice-test--cli "unset" "Weekly Review" "tags" "aliases")
    (should (string-prefix-p "---\n---\nBack to"
                             (pumice-test--read v "Weekly Review.md")))
    (should-error (pumice-test--cli "set" "Home" "no-equals-sign")
                  :type 'pumice-cli-usage)))

(ert-deftest pumice-test-cli-rename-and-trash ()
  (pumice-test-with-vault
    ;; No slash: the note stays in its folder.
    (should (equal (concat (expand-file-name "Notes/Work/Lattice.md" root) "\n")
                   (pumice-test--cli "rename" "Trellis" "Lattice")))
    (should (string-search "[[Notes/Work/Lattice]]" (pumice-test--read v "Home.md")))
    ;; A slash: a path from the vault root.  A leading one is the root.
    (pumice-test--cli "rename" "Lattice" "/Lattice")
    (should (file-exists-p (expand-file-name "Lattice.md" root)))
    (should (string-search "[[Lattice]]" (pumice-test--read v "Home.md")))
    (should-error (pumice-test--cli "rename" "Lattice" "Lattice")
                  :type 'user-error)
    (should-error (pumice-test--cli "rename" "Lattice" "Home") :type 'user-error)
    ;; Trashing keeps what is already in the trash.
    (should (equal (concat (expand-file-name ".trash/Clojure.md" root) "\n")
                   (pumice-test--cli "trash" "Notes/Clojure")))
    (should (equal (concat (expand-file-name ".trash/Clojure 2.md" root) "\n")
                   (pumice-test--cli "trash" "Clojure")))
    (should-error (pumice-test--cli "path" "Clojure") :type 'user-error)))

(ert-deftest pumice-test-cli-choosing-the-vault ()
  (pumice-test-with-vault
    (should (equal (concat (directory-file-name root) "\n")
                   (pumice-test--cli "root")))
    (should (equal (concat (directory-file-name root) "\n")
                   (pumice-test--cli "root" "--vault" root)))
    (should (equal (concat (directory-file-name root) "\n")
                   (pumice-test--cli "--vault"
                                     (upcase (file-name-nondirectory
                                              (directory-file-name root)))
                                     "root")))
    (should-error (pumice-test--cli "root" "--vault" "No such vault")
                  :type 'user-error)
    (should (string-prefix-p "* " (pumice-test--cli "vaults")))
    (should (string-search "daily_format: YYYY/MM/MMM D, yyyy\n"
                           (pumice-test--cli "config")))
    (should (string-search "new_note_folder: Inbox\n" (pumice-test--cli "config")))))

(ert-deftest pumice-test-cli-usage ()
  (pumice-test-with-vault
    (should (string-prefix-p "pumice: " (pumice-test--cli)))
    (should (string-prefix-p "pumice: " (pumice-test--cli "list" "--help")))
    ;; Under another name it calls itself that.
    (let ((pumice-cli-program "notes"))
      (should (string-prefix-p "notes: " (pumice-test--cli)))
      (should (string-search "\nUsage: notes [" (pumice-test--cli)))
      (let ((err (should-error (pumice-test--cli "nonsense")
                               :type 'pumice-cli-usage)))
        (should (string-search "Try: notes help" (cadr err)))))
    (dolist (args '(("nonsense") ("list" "--bogus") ("list" "extra")
                    ("path") ("backlinks" "Home" "--folder" "Notes")
                    ("list" "--limit" "many") ("list" "--folder")))
      (should-error (apply #'pumice-test--cli args) :type 'pumice-cli-usage))
    ;; Only words starting with -- are options, and a lone -- ends them.
    (should (equal '(nil "-7" "--x")
                   (pumice-cli--parse '("-7" "--" "--x"))))
    (should (equal '((("--where" "b" "a") ("--json" . t) ("--tag" . "x")) "list")
                   (pumice-cli--parse
                    '("list" "--tag=x" "--json" "--where" "a" "--where" "b"))))))

(defconst pumice-test--launcher
  (expand-file-name "../bin/pumice"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The shell script that starts the command line.")

(ert-deftest pumice-test-launcher ()
  "The launcher finds the Lisp files, also when run through a symlink."
  (skip-unless (not (memq system-type '(windows-nt ms-dos))))
  (pumice-test-with-vault
    (let* ((bin (file-name-as-directory (make-temp-file "pumice-bin" t)))
           (link (expand-file-name "notes" bin))
           (process-environment
            (append (list (concat "PUMICE_EMACS="
                                  (expand-file-name invocation-name
                                                    invocation-directory))
                          (concat "PUMICE_VAULT=" root))
                    process-environment)))
      (unwind-protect
          (progn
            (make-symbolic-link pumice-test--launcher link)
            (should (member "Home.md"
                            (process-lines pumice-test--launcher "list")))
            (should (equal (list (directory-file-name root))
                           (process-lines link "root")))
            (should (string-prefix-p "notes: "
                                     (car (process-lines link "help")))))
        (delete-directory bin t)))))

;;; pumice-test.el ends here
