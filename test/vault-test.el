;;; vault-test.el --- Tests for vault.el -*- lexical-binding: t; -*-

;; Run from the repo root:
;;   emacs --batch -L emacs/command-centre/lisp \
;;     -l emacs/command-centre/test/vault-test.el -f ert-run-tests-batch-and-exit
;;
;; Every test builds a throwaway vault under `temporary-file-directory', so
;; nothing here can touch a real one.

(require 'ert)
(require 'vault)
(require 'vault-commands)
(require 'vault-refactor)
(require 'vault-ui)
(require 'vault-tree)
(require 'vault-cli)

(vault-global-mode 1)

(defconst vault-test--files
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

(defmacro vault-test-with-vault (&rest body)
  "Run BODY with `v' bound to a freshly indexed fixture vault."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory
                 (file-truename (make-temp-file "vault-test" t))))
          (vault-directories (list root))
          (vault-default-root root)
          (vault--cache (make-hash-table :test 'equal))
          (vault-refresh-interval 0))
     (unwind-protect
         (progn
           (pcase-dolist (`(,rel . ,content) vault-test--files)
             (let ((path (expand-file-name rel root)))
               (make-directory (file-name-directory path) t)
               (write-region content nil path nil 'silent)))
           (let ((v (vault-current)))
             (ignore v)
             ,@body))
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p root (buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun vault-test--note (v rel)
  "Return the note at REL (with extension) in V."
  (vault-note-at v (expand-file-name rel (vault--root v))))

(defun vault-test--read (v rel)
  "Return the content of REL in V as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name rel (vault--root v)))
    (buffer-string)))

;;; Index

(ert-deftest vault-test-index-skips-hidden-directories ()
  (vault-test-with-vault
    (should (= 9 (hash-table-count (vault--notes v))))
    (should-not (vault-test--note v ".trash/Deleted.md"))
    (should (member "Follow-ups.base" (vault--files v)))))

(ert-deftest vault-test-frontmatter-and-tags ()
  (vault-test-with-vault
    (let ((review (vault-test--note v "Weekly Review.md")))
      (should (equal '("Review" "Weekly") (vault-note-aliases review)))
      (should (equal '("gtd" "routine") (vault-note-tags review))))
    (should (equal '("work/project")
                   (vault-note-tags
                    (vault-test--note v "Notes/Work/Trellis.md"))))))

(ert-deftest vault-test-links-in-properties-count ()
  (vault-test-with-vault
    (let ((note (vault-test--note v "Notes/Work/Clojure.md")))
      (should (equal '("Trellis")
                     (mapcar #'vault-link-target (vault-note-links note))))
      (should-not (vault-note-tags note)))))

(ert-deftest vault-test-links-skip-code-fences ()
  (vault-test-with-vault
    (let ((note (vault-test--note v "Ongoing work.md")))
      (should (equal '("Home" "Weekly Review.md")
                     (mapcar #'vault-link-target (vault-note-links note))))
      (should (equal "Goals"
                     (vault-link-heading (car (vault-note-links note)))))
      (should-not (vault-note-tags note)))))

(ert-deftest vault-test-refresh-picks-up-changes ()
  (vault-test-with-vault
    (let ((tick (vault--tick v)))
      (vault-refresh v t)
      (should (= tick (vault--tick v)))
      (write-region "[[Home]]\n" nil (expand-file-name "New.md" root))
      (delete-file (expand-file-name "Notes/Clojure.md" root))
      (vault-refresh v t)
      (should (> (vault--tick v) tick))
      (should (vault-test--note v "New.md"))
      (should-not (vault-test--note v "Notes/Clojure.md")))))

;;; Resolution

(ert-deftest vault-test-resolve ()
  (vault-test-with-vault
    (let ((home (vault-test--note v "Home.md"))
          (trellis (vault-test--note v "Notes/Work/Trellis.md")))
      (should (eq home (vault-resolve v "home")))
      (should (eq trellis (vault-resolve v "Notes/Work/Trellis")))
      (should (eq trellis (vault-resolve v "Work/Trellis.md")))
      (should-not (vault-resolve v "Nowhere"))
      (should (eq home (vault-resolve v "" home)))
      ;; Two notes are called Clojure.  The link's own folder wins, and
      ;; without one the shorter path does.
      (should (equal "Notes/Work/Clojure"
                     (vault-note-rel (vault-resolve v "Clojure" trellis))))
      (should (equal "Notes/Clojure"
                     (vault-note-rel (vault-resolve v "Clojure" home)))))))

(ert-deftest vault-test-resolve-file ()
  (vault-test-with-vault
    (should (string-suffix-p "Attachments/diagram.png"
                             (vault-resolve-file v "diagram.png")))
    (should (vault-resolve-file v "Follow-ups.base"))
    (should-not (vault-resolve-file v "missing.png"))))

(ert-deftest vault-test-backlinks ()
  (vault-test-with-vault
    (let ((sources (mapcar (lambda (pair) (vault-note-name (car pair)))
                           (vault-backlinks v (vault-test--note v "Home.md")))))
      (should (equal '("Aug 7, 2026" "Ongoing work" "Weekly Review")
                     (sort sources #'string<))))
    ;; A Markdown link with an escaped space counts.
    (should (member "Ongoing work"
                    (mapcar (lambda (pair) (vault-note-name (car pair)))
                            (vault-backlinks
                             v (vault-test--note v "Weekly Review.md")))))))

(ert-deftest vault-test-link-name ()
  (vault-test-with-vault
    (let ((home (vault-test--note v "Home.md")))
      (should (equal "Weekly Review"
                     (vault-link-name
                      v (vault-test--note v "Weekly Review.md") home)))
      (should (equal "Notes/Work/Clojure"
                     (vault-link-name
                      v (vault-test--note v "Notes/Work/Clojure.md") home))))))

;;; Dates and settings

(ert-deftest vault-test-format-date ()
  (let ((time (encode-time '(0 5 9 7 8 2026 nil -1 nil))))
    (should (equal "2026/08/Aug 7, 2026"
                   (vault-format-date "YYYY/MM/MMM D, yyyy" time)))
    (should (equal "2026-08-07" (vault-format-date "YYYY-MM-DD" time)))
    (should (equal "Day 07 at 09:05"
                   (vault-format-date "[Day] DD [at] HH:mm" time)))))

(ert-deftest vault-test-daily-path ()
  (vault-test-with-vault
    (should (equal (expand-file-name "Day Notes/2026/08/Aug 7, 2026.md" root)
                   (vault-daily-path
                    v (encode-time '(0 0 12 7 8 2026 nil -1 nil)))))
    (should (equal "Inbox" (vault-setting v :new-note-folder)))))

;;; Following and inserting links

(defmacro vault-test-in-note (rel &rest body)
  "Visit REL in the fixture vault `v' and run BODY there."
  (declare (indent 1) (debug t))
  `(with-current-buffer (find-file-noselect (expand-file-name ,rel root))
     (goto-char (point-min))
     ,@body))

(ert-deftest vault-test-link-at-point ()
  (vault-test-with-vault
    (vault-test-in-note "Home.md"
      (should-not (vault-link-at-point))
      (search-forward "Ongoing")
      (pcase-let ((`(,link ,beg ,end) (vault-link-at-point)))
        (should (equal "Ongoing work" (vault-link-target link)))
        (should (equal "Projects" (vault-link-alias link)))
        (should (equal "[[Ongoing work|Projects]]"
                       (buffer-substring beg end)))))))

(ert-deftest vault-test-follow ()
  (vault-test-with-vault
    (save-window-excursion
      (vault-test-in-note "Ongoing work.md"
        (search-forward "[[Home")
        (should (vault-follow))
        (should (equal "Home.md" (file-name-nondirectory buffer-file-name))))
      ;; A dangling link starts the note where the vault keeps new ones,
      ;; without creating a file or a folder until it is saved.
      (vault-test-in-note "Home.md"
        (search-forward "[[Nowhere")
        (should (vault-follow))
        (should (equal (expand-file-name "Inbox/Nowhere.md" root)
                       buffer-file-name))
        (should-not (file-exists-p (expand-file-name "Inbox" root))))
      (vault-test-in-note "Home.md"
        (search-forward "Follow-ups")
        (should (vault-follow))
        (should (equal "Follow-ups.base"
                       (file-name-nondirectory buffer-file-name))))
      (vault-test-in-note "Home.md"
        (should-not (vault-follow))))))

(ert-deftest vault-test-follow-to-heading ()
  (vault-test-with-vault
    (save-window-excursion
      (with-temp-buffer
        (vault-open v "Weekly Review" "checklist")
        (should (looking-at-p "## Checklist"))))))

(ert-deftest vault-test-missing-attachment-is-not-a-new-note ()
  (vault-test-with-vault
    (should-error (vault-open v "gone.png") :type 'user-error)))

(ert-deftest vault-test-toggle-checkbox ()
  (vault-test-with-vault
    (vault-test-in-note "Weekly Review.md"
      (search-forward "Empty the inbox")
      (should (vault-follow))
      (should (looking-back "- \\[x\\] Empty the inbox" (pos-bol)))
      (should (vault-toggle-checkbox))
      (should (looking-back "- \\[ \\] Empty the inbox" (pos-bol))))))

(ert-deftest vault-test-link-text ()
  (vault-test-with-vault
    (let ((review (vault-test--note v "Weekly Review.md"))
          (clojure (vault-test--note v "Notes/Work/Clojure.md")))
      (vault-test-in-note "Home.md"
        (should (equal "[[Weekly Review]]"
                       (vault--link-text v (cons review nil))))
        (should (equal "[[Weekly Review|Review]]"
                       (vault--link-text v (cons review "Review"))))
        (should (equal "[[Weekly Review|the ritual]]"
                       (vault--link-text v (cons review nil) "the ritual")))
        (should (equal "[[Notes/Work/Clojure]]"
                       (vault--link-text v (cons clojure nil))))
        (should (equal "[[Brand new]]" (vault--link-text v "Brand new")))))))

(ert-deftest vault-test-next-link ()
  (vault-test-with-vault
    (vault-test-in-note "Home.md"
      (vault-next-link)
      (should (looking-at-p "\\[\\[Weekly Review"))
      (vault-next-link)
      (should (looking-at-p "\\[\\[Ongoing work"))
      (vault-next-link)
      (should (looking-at-p "!\\[\\[Follow-ups"))
      (vault-next-link)
      (should (looking-at-p "\\[\\[Notes/Work"))
      (vault-previous-link 2)
      (should (looking-at-p "\\[\\[Ongoing work")))))

;;; Templates, daily notes, capture

(ert-deftest vault-test-expand-template ()
  (let ((time (encode-time '(0 5 9 7 8 2026 nil -1 nil))))
    (should (equal "T 2026-08-07 09:05 Aug 7"
                   (vault--expand-template
                    "{{title}} {{date}} {{time}} {{date:MMM D}}" "T" time)))))

(ert-deftest vault-test-daily-note-from-template ()
  (vault-test-with-vault
    (let ((time (encode-time '(0 0 12 9 11 2026 nil -1 nil))))
      (with-current-buffer (vault--daily-buffer v time)
        (should (equal (expand-file-name "Day Notes/2026/11/Nov 9, 2026.md" root)
                       buffer-file-name))
        (should (equal "## Log\n\nNov 9, 2026 on 2026-11-09\n" (buffer-string)))))
    ;; Asking twice for a note that is not on disk yet returns the same
    ;; buffer, without a prompt about the missing folder.
    (let ((time (encode-time '(0 0 12 10 11 2026 nil -1 nil))))
      (should (eq (vault--daily-buffer v time) (vault--daily-buffer v time)))
      (should-not (buffer-local-value 'buffer-read-only
                                      (vault--daily-buffer v time))))
    ;; An existing daily note is left as it is.
    (with-current-buffer
        (vault--daily-buffer v (encode-time '(0 0 12 14 8 2026 nil -1 nil)))
      (should (equal "## Log\n" (buffer-string))))))

(ert-deftest vault-test-daily-step ()
  (vault-test-with-vault
    (cl-letf (((symbol-function 'vault--now)
               (lambda () (encode-time '(0 0 12 9 11 2026 nil -1 nil)))))
      (should (equal '("Aug 7, 2026" "Aug 14, 2026")
                     (mapcar (lambda (entry) (file-name-base (cdr entry)))
                             (vault--daily-notes v))))
      (save-window-excursion
        (vault-test-in-note "Day Notes/2026/08/Aug 14, 2026.md"
          (vault-daily-previous)
          (should (equal "Aug 7, 2026" (file-name-base buffer-file-name)))
          (vault-daily-next)
          (should (equal "Aug 14, 2026" (file-name-base buffer-file-name)))
          (should-error (vault-daily-next) :type 'user-error))))))

(ert-deftest vault-test-log ()
  (vault-test-with-vault
    (cl-letf (((symbol-function 'vault--now)
               (lambda () (encode-time '(0 30 8 14 8 2026 nil -1 nil)))))
      (let ((rel "Day Notes/2026/08/Aug 14, 2026.md"))
        (vault-log "first")
        (should (equal "## Log\n\n- 08:30 first\n" (vault-test--read v rel)))
        (vault-log "second")
        (should (equal "## Log\n\n- 08:30 first\n- 08:30 second\n"
                       (vault-test--read v rel)))
        ;; Entries stay inside the log section when another one follows.
        (write-region "## Log\n\n## Follow up\n\ntail\n" nil
                      (expand-file-name rel root))
        (with-current-buffer (find-buffer-visiting (expand-file-name rel root))
          (revert-buffer t t))
        (vault-log "third")
        (should (equal "## Log\n\n- 08:30 third\n\n## Follow up\n\ntail\n"
                       (vault-test--read v rel)))))))

(ert-deftest vault-test-capture-path ()
  (vault-test-with-vault
    (should (equal (expand-file-name "Inbox/Idea.md" root)
                   (vault--new-note-path v "Idea")))
    (should (equal (expand-file-name "Projects/Idea.md" root)
                   (vault--new-note-path v "Projects/Idea.md")))))

(ert-deftest vault-test-tags ()
  (vault-test-with-vault
    (let ((tags (vault-tags v)))
      (should (equal '("gtd" "routine" "work" "work/project")
                     (mapcar #'car tags)))
      (should (equal '("Home" "Weekly Review")
                     (sort (mapcar #'vault-note-name (cdr (assoc "gtd" tags)))
                           #'string<))))))

;;; Renaming

(ert-deftest vault-test-rename-rewrites-links ()
  (vault-test-with-vault
    (let ((count (vault-rename-note v (vault-test--note v "Weekly Review.md")
                                    "Routines/Review ritual")))
      (should (= 2 count))
      (should (file-exists-p (expand-file-name "Routines/Review ritual.md" root)))
      (should-not (file-exists-p (expand-file-name "Weekly Review.md" root)))
      (should (string-search "[[Review ritual]] and [[Ongoing work|Projects]]"
                             (vault-test--read v "Home.md")))
      (should (string-search "[the review](Routines/Review%20ritual.md)"
                             (vault-test--read v "Ongoing work.md")))
      ;; Everything that pointed at the note still does.
      (should (= 2 (length (vault-backlinks
                            v (vault-test--note v "Routines/Review ritual.md"))))))))

(ert-deftest vault-test-rename-keeps-path-links-and-suffixes ()
  (vault-test-with-vault
    (vault-rename-note v (vault-test--note v "Notes/Work/Trellis.md")
                       "Notes/Work/Lattice")
    (should (string-search "[[Notes/Work/Lattice]] #gtd"
                           (vault-test--read v "Home.md")))
    (vault-rename-note v (vault-test--note v "Home.md") "Start")
    (should (string-search "See [[Start#Goals]]"
                           (vault-test--read v "Ongoing work.md")))))

(ert-deftest vault-test-rename-into-a-shared-name-uses-paths ()
  (vault-test-with-vault
    (vault-rename-note v (vault-test--note v "Weekly Review.md") "Clojure")
    (should (string-search "[[Clojure]] and" (vault-test--read v "Home.md")))
    ;; From Home, [[Clojure]] must now mean the new root-level note.
    (should (equal "Clojure"
                   (vault-note-rel
                    (vault-resolve v "Clojure"
                                   (vault-test--note v "Home.md")))))))

(ert-deftest vault-test-rename-moves-visiting-buffers ()
  (vault-test-with-vault
    (let ((home (find-file-noselect (expand-file-name "Home.md" root)))
          (review (find-file-noselect (expand-file-name "Weekly Review.md" root))))
      (with-current-buffer home
        (goto-char (point-max))
        (insert "unsaved\n"))
      (vault-rename-note v (vault-test--note v "Weekly Review.md") "Review")
      (should (equal (expand-file-name "Review.md" root)
                     (buffer-file-name review)))
      ;; Home had unsaved edits, so it is updated but not written.
      (with-current-buffer home
        (should (buffer-modified-p))
        (should (string-search "[[Review]]" (buffer-string))))
      (should (string-search "[[Weekly Review]]"
                             (vault-test--read v "Home.md"))))))

(ert-deftest vault-test-rename-refuses-to-overwrite ()
  (vault-test-with-vault
    (should-error (vault-rename-note v (vault-test--note v "Home.md")
                                     "Ongoing work")
                  :type 'user-error)
    (should (file-exists-p (expand-file-name "Home.md" root)))))

(ert-deftest vault-test-extract ()
  (vault-test-with-vault
    (vault-test-in-note "Notes/Clojure.md"
      (vault-extract "Aside" (progn (search-forward "Mentions") (match-beginning 0))
                     (point-max))
      (should (equal "The general one. [[Aside]]" (buffer-string))))
    (should (equal "Mentions Trellis in passing.\n"
                   (vault-test--read v "Inbox/Aside.md")))))

;;; Note buffers

(ert-deftest vault-test-mode-turns-on-only-in-vaults ()
  (vault-test-with-vault
    (vault-test-in-note "Home.md"
      (should vault-mode))
    (vault-test-in-note "Follow-ups.base"
      (should-not vault-mode)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/elsewhere/README.md")
    (let ((vault-directories (list "/nonexistent-vault/")))
      (vault-mode-maybe))
    (should-not vault-mode)
    (setq buffer-file-name nil)))

(ert-deftest vault-test-link-faces ()
  (vault-test-with-vault
    (vault-test-in-note "Home.md"
      (font-lock-mode 1)
      (font-lock-ensure)
      (cl-flet ((face-at (text)
                  (goto-char (point-min))
                  (search-forward text)
                  (get-text-property (match-beginning 0) 'face)))
        (should (eq 'vault-link (face-at "Weekly Review")))
        (should (eq 'vault-link-unresolved (face-at "Nowhere")))
        ;; With an alias the alias is the link and the target recedes.
        (should (eq 'vault-markup (face-at "Ongoing work")))
        (should (eq 'vault-link (face-at "Projects")))
        (should (eq 'vault-link (face-at "Follow-ups.base")))
        (should (eq 'vault-tag (face-at "#gtd")))))))

(defun vault-test--complete (text)
  "Insert TEXT at the end of the buffer and return (PREFIX . CANDIDATES)."
  (goto-char (point-max))
  (insert text)
  (pcase-let ((`(,beg ,end ,table . ,_) (vault-completion-at-point)))
    (and beg (cons (buffer-substring beg end)
                   (all-completions "" table)))))

(ert-deftest vault-test-completion ()
  (vault-test-with-vault
    (vault-test-in-note "Home.md"
      (should-not (vault-test--complete "plain text"))
      (pcase-let ((`(,prefix . ,names) (vault-test--complete "\n[[Week")))
        (should (equal "Week" prefix))
        (should (member "Weekly Review" names))
        (should (member "Weekly Review|Review" names))
        ;; Of two notes called Clojure, the one a bare [[Clojure]] reaches
        ;; from here keeps the short name and the other is offered by path.
        (should (member "Clojure" names))
        (should (member "Notes/Work/Clojure" names)))
      (should (equal '("Che" "Checklist")
                     (vault-test--complete "\n[[Weekly Review#Che")))
      (pcase-let ((`(,prefix . ,tags) (vault-test--complete "\n#wo")))
        (should (equal "wo" prefix))
        (should (member "work/project" tags)))
      (set-buffer-modified-p nil))))

;;; Mentions and the panel

(ert-deftest vault-test-unlinked-mentions ()
  (skip-unless (executable-find "rg"))
  (vault-test-with-vault
    (let* ((trellis (vault-test--note v "Notes/Work/Trellis.md"))
           (mentions (vault-unlinked-mentions v trellis)))
      ;; Home links to it, so only the plain mention counts.
      (should (equal (list (list (expand-file-name "Notes/Clojure.md" root) 1
                                 "The general one. Mentions Trellis in passing."))
                     mentions))
      (should (vault-link-mention (expand-file-name "Notes/Clojure.md" root)
                                  1 trellis))
      (should (equal "The general one. Mentions [[Trellis]] in passing.\n"
                     (vault-test--read v "Notes/Clojure.md")))
      (should-not (vault-unlinked-mentions v trellis))
      ;; Home, the property in Work/Clojure, and now Notes/Clojure.
      (should (= 3 (length (vault-backlinks v trellis)))))))

(ert-deftest vault-test-panel ()
  (vault-test-with-vault
    (save-window-excursion
      (find-file (expand-file-name "Home.md" root))
      (delete-other-windows)
      (vault-panel-toggle)
      (unwind-protect
          (with-current-buffer vault-panel-buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-prefix-p "Home\n" text))
              (should (string-search "Backlinks  3" text))
              (should (string-search "    Back to [[Home]]." text))
              (should (string-search "Links  5" text))
              (should (string-search "  Nowhere\n" text)))
            ;; RET on a context line lands on that line of the source.
            (select-window (get-buffer-window vault-panel-buffer))
            (goto-char (point-min))
            (search-forward "Back to")
            (vault-panel-visit)
            (should (equal "Weekly Review.md"
                           (file-name-nondirectory buffer-file-name)))
            (should (looking-at-p "Back to \\[\\[Home\\]\\]"))
            ;; The panel follows the note that is now selected.
            (vault-panel--sync)
            (with-current-buffer vault-panel-buffer
              (should (string-prefix-p "Weekly Review\n" (buffer-string)))
              (should (string-search "Backlinks  2" (buffer-string)))))
        (when (get-buffer-window vault-panel-buffer) (vault-panel-toggle))
        (kill-buffer vault-panel-buffer)))))

;;; Folder tree

(defmacro vault-test-with-tree (rel &rest body)
  "Run BODY in the folder tree, opened from the note at REL."
  (declare (indent 1) (debug t))
  `(vault-test-with-vault
     (save-window-excursion
       (find-file (expand-file-name ,rel root))
       (delete-other-windows)
       (vault-tree)
       (unwind-protect
           (progn ,@body)
         (when (get-buffer vault-tree-buffer)
           (kill-buffer vault-tree-buffer))))))

(ert-deftest vault-test-tree-lists-folders-first ()
  (vault-test-with-tree "Home.md"
    (should (equal (concat "▸ Attachments\n▸ Day Notes  2\n▸ Notes  3\n"
                           "▸ Templates  1\n  Home\n  Ongoing work\n"
                           "  Weekly Review\n  Follow-ups.base\n")
                   (buffer-substring-no-properties (point-min) (point-max))))
    ;; Opened from Home, so point is there and it is marked as current.
    (should (looking-at-p "  Home$"))
    (should (eq 'vault-tree-current (get-text-property (+ (point) 2) 'face)))
    ;; Commands run from the tree act on the vault it shows.
    (should (eq v (vault-current)))))

(ert-deftest vault-test-tree-follows-the-current-note ()
  (vault-test-with-tree "Home.md"
    (select-window (get-mru-window nil nil t))
    (find-file (expand-file-name "Notes/Work/Trellis.md" root))
    (vault-tree--sync)
    (with-selected-window (get-buffer-window vault-tree-buffer)
      (should (string-search
               (concat "▾ Notes  3\n  ▾ Work  2\n      Clojure\n"
                       "      Trellis\n    Clojure\n")
               (buffer-substring-no-properties (point-min) (point-max))))
      (should (looking-at-p "      Trellis$")))))

(ert-deftest vault-test-tree-steps-in-and-out ()
  (vault-test-with-tree "Notes/Work/Trellis.md"
    (should (looking-at-p "      Trellis$"))
    (vault-tree-collapse)
    (should (looking-at-p "  ▾ Work"))
    (vault-tree-collapse)
    (should (looking-at-p "  ▸ Work"))
    (should-not (string-search "Trellis" (buffer-string)))
    (vault-tree-expand)
    (should (looking-at-p "  ▾ Work"))
    (vault-tree-expand)
    (should (looking-at-p "      Clojure$"))
    (vault-tree-collapse-all)
    (should (looking-at-p "▸ Notes"))
    (vault-tree-expand-all)
    ;; Version order: the 7th sorts before the 14th.
    (should (string-search
             "    ▾ 08  2\n        Aug 7, 2026\n        Aug 14, 2026\n"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest vault-test-tree-opens-notes ()
  (vault-test-with-tree "Home.md"
    (let ((tree (selected-window)))
      (vault-tree--goto (expand-file-name "Weekly Review.md" root))
      (vault-tree-peek)
      (should (eq tree (selected-window)))
      (should (equal "Weekly Review.md"
                     (file-name-nondirectory
                      (buffer-file-name
                       (window-buffer (get-mru-window nil nil t))))))
      (should (looking-at-p "  Weekly Review$"))
      (should (eq 'vault-tree-current
                  (get-text-property (+ (point) 2) 'face)))
      (vault-tree--goto (expand-file-name "Ongoing work.md" root))
      (vault-tree-visit)
      (should-not (eq tree (selected-window)))
      (should (equal "Ongoing work.md"
                     (file-name-nondirectory buffer-file-name))))))

(ert-deftest vault-test-tree-new-note ()
  (vault-test-with-tree "Home.md"
    ;; On a note the folder is the one holding it; on a folder, itself.
    (should (equal (directory-file-name root) (vault-tree--folder)))
    (vault-tree--goto (expand-file-name "Notes" root))
    (should (equal (expand-file-name "Notes" root) (vault-tree--folder)))
    (vault-tree-new-note (vault-tree--folder) "Idea")
    (should (equal (expand-file-name "Notes/Idea.md" root) buffer-file-name))
    (should-not (file-exists-p buffer-file-name))
    (should-not buffer-read-only)))

(ert-deftest vault-test-tree-rename ()
  (vault-test-with-tree "Home.md"
    (vault-tree-rename (expand-file-name "Weekly Review.md" root)
                       "Notes/Review")
    (should (file-exists-p (expand-file-name "Notes/Review.md" root)))
    (should (string-search "[[Review]]" (vault-test--read v "Home.md")))
    ;; The tree unfolds the new folder and lands on the note.
    (should (looking-at-p "    Review$"))
    (should (string-search "▾ Notes  4\n" (buffer-string)))))

(ert-deftest vault-test-tree-sorts-by-change ()
  (vault-test-with-tree "Home.md"
    (pcase-dolist (`(,rel . ,age) '(("Weekly Review.md" . 60)
                                    ("Ongoing work.md" . 120)
                                    ("Home.md" . 180)))
      (set-file-times (expand-file-name rel root) (time-subtract nil age)))
    (vault-tree-refresh)
    (should (string-search "  Home\n  Ongoing work\n  Weekly Review\n"
                           (buffer-string)))
    (vault-tree-sort)
    (should (string-search "  Weekly Review\n  Ongoing work\n  Home\n"
                           (buffer-string)))
    (should (string-search "by date" header-line-format))))

(ert-deftest vault-test-side-windows-open-things-in-the-main-window ()
  (vault-test-with-tree "Home.md"
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
      (should (eq (get-buffer vault-tree-buffer) (window-buffer tree))))))

;;; Properties

(ert-deftest vault-test-frontmatter-properties ()
  (vault-test-with-vault
    (should (equal '(("aliases" "Review" "Weekly") ("tags" "gtd" "routine"))
                   (vault-note-props (vault-test--note v "Weekly Review.md"))))
    (should (equal '(("parent" . "[[Trellis]]") ("colour" . "#fff"))
                   (vault-note-props
                    (vault-test--note v "Notes/Work/Clojure.md"))))
    (should-not (vault-note-props (vault-test--note v "Home.md")))))

(defun vault-test--set-property (text key value)
  "Return TEXT after setting its frontmatter property KEY to VALUE."
  (with-temp-buffer
    (insert text)
    (vault-set-property key value)
    (buffer-string)))

(ert-deftest vault-test-set-property ()
  ;; A note without frontmatter gets some.
  (should (equal "---\nstatus: done\n---\nBody\n"
                 (vault-test--set-property "Body\n" "status" "done")))
  ;; A new key goes last; an existing one is replaced where it stands.
  (should (equal "---\na: 1\nb: 2\n---\n"
                 (vault-test--set-property "---\na: 1\n---\n" "b" "2")))
  (should (equal "---\na: 9\nb: 2\n---\n"
                 (vault-test--set-property "---\na: 1\nb: 2\n---\n" "a" "9")))
  ;; A list is replaced along with its items, and can be written.
  (should (equal "---\ntags: x\nb: 2\n---\n"
                 (vault-test--set-property
                  "---\ntags:\n  - one\n  - two\nb: 2\n---\n" "tags" "x")))
  (should (equal "---\ntags:\n  - one\n  - two\n---\n"
                 (vault-test--set-property "---\ntags: x\n---\n" "tags"
                                           '("one" "two"))))
  ;; Removing a key takes its items with it and leaves the body alone.
  (should (equal "---\nb: 2\n---\ntags: body\n"
                 (vault-test--set-property
                  "---\ntags:\n  - one\nb: 2\n---\ntags: body\n" "tags" nil)))
  ;; Values YAML would misread are quoted.
  (should (equal "---\nparent: \"[[Home]]\"\n---\n"
                 (vault-test--set-property "---\n---\n" "parent" "[[Home]]")))
  (should (equal "---\nnext: \"Call: the \\\"bank\\\"\"\n---\n"
                 (vault-test--set-property "---\n---\n" "next"
                                           "Call: the \"bank\"")))
  (should (equal "---\nnext: \"\"\n---\n"
                 (vault-test--set-property "---\n---\n" "next" "")))
  (should (equal "---\ndone: true\n---\n"
                 (vault-test--set-property "---\n---\n" "done" "true")))
  ;; What is written reads back as what was meant.
  (with-temp-buffer
    (insert "Body\n")
    (should (vault-set-property "next" "Call: the \"bank\" #1"))
    (should (equal '(("next" . "Call: the \"bank\" #1")) (vault--frontmatter)))
    (should-not (vault-set-property "next" "Call: the \"bank\" #1"))))

;;; Command line

(defun vault-test--cli (&rest args)
  "Run the notes command line ARGS in the fixture vault; return its output."
  (let ((process-environment (cons "NOTES_VAULT" process-environment))
        (default-directory temporary-file-directory))
    (with-output-to-string (vault-cli-run args))))

(defun vault-test--cli-lines (&rest args)
  "Run the notes command line ARGS and return its output lines, sorted."
  (sort (split-string (apply #'vault-test--cli args) "\n" t) #'string<))

(defmacro vault-test-at (time &rest body)
  "Run BODY with the clock stopped at TIME, a list for `encode-time'."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'vault--now)
              (lambda () (encode-time ',time))))
     ,@body))

(ert-deftest vault-test-cli-list ()
  (vault-test-with-vault
    (should (equal '("Home.md" "Weekly Review.md")
                   (vault-test--cli-lines "list" "--tag" "gtd")))
    (should (equal '("Notes/Work/Trellis.md")
                   (vault-test--cli-lines "list" "--tag" "#work")))
    (should (equal '("Notes/Clojure.md" "Notes/Work/Clojure.md"
                     "Notes/Work/Trellis.md")
                   (vault-test--cli-lines "list" "--folder" "Notes/")))
    ;; Templates are left out unless asked for.
    (should (= 8 (length (vault-test--cli-lines "list"))))
    (should (member "Templates/Day note.md"
                    (vault-test--cli-lines "list" "--templates")))
    (should (= 2 (length (vault-test--cli-lines "list" "--limit" "2"))))
    (should (equal (list (expand-file-name "Notes/Clojure.md" root)
                         (expand-file-name "Notes/Work/Trellis.md" root))
                   (vault-test--cli-lines "list" "--abs" "--folder" "Notes"
                                          "--where" "!parent"
                                          "--where" "!tags")))))

(ert-deftest vault-test-cli-where ()
  (vault-test-with-vault
    (should (equal '("Notes/Work/Clojure.md")
                   (vault-test--cli-lines "list" "--where" "colour=#fff")))
    (should (equal '("Notes/Work/Clojure.md")
                   (vault-test--cli-lines "list" "--where" "colour == \"#fff\"")))
    (should (equal '("Notes/Work/Clojure.md")
                   (vault-test--cli-lines "list" "--where" "parent")))
    ;; A list property matches on any of its items.
    (should (equal '("Weekly Review.md")
                   (vault-test--cli-lines "list" "--where" "tags=routine")))
    (should (equal '("Notes/Work/Trellis.md")
                   (vault-test--cli-lines "list" "--folder" "Notes/Work"
                                          "--where" "colour!=#fff")))
    (should (equal "Notes/Work/Clojure.md\t#fff\t[[Trellis]]\t\n"
                   (vault-test--cli "list" "--where" "colour"
                                    "--show" "colour, parent,tags")))
    (should (equal "Weekly Review.md\tgtd, routine\n"
                   (vault-test--cli "list" "--where" "aliases=Review"
                                    "--show" "tags")))))

(ert-deftest vault-test-cli-json ()
  (vault-test-with-vault
    (let ((notes (json-parse-string
                  (vault-test--cli "list" "--json" "--where" "colour")
                  :object-type 'alist)))
      (should (= 1 (length notes)))
      (let-alist (aref notes 0)
        (should (equal "Notes/Work/Clojure.md" .path))
        (should (equal "#fff" .properties.colour))
        (should (equal [] .tags))))
    (let-alist (json-parse-string (vault-test--cli "info" "--json" "Weekly Review")
                                  :object-type 'alist)
      (should (equal ["Review" "Weekly"] .aliases))
      (should (equal ["gtd" "routine"] .properties.tags))
      (should (= 1 .links))
      (should (= 2 .backlinks)))
    ;; Nothing found is still an array.
    (should (equal "[]\n" (vault-test--cli "list" "--json" "--tag" "none")))))

(ert-deftest vault-test-cli-find-notes ()
  (vault-test-with-vault
    (let ((review (concat (expand-file-name "Weekly Review.md" root) "\n")))
      (should (equal review (vault-test--cli "path" "Weekly Review")))
      (should (equal review (vault-test--cli "path" "weekly review.md")))
      ;; An alias, a file path, and a path from the root all work.
      (should (equal review (vault-test--cli "path" "Review")))
      (should (equal review (vault-test--cli "path" (string-trim review))))
      (should (equal (concat (expand-file-name "Notes/Work/Clojure.md" root) "\n")
                     (vault-test--cli "path" "Notes/Work/Clojure.md"))))
    (should (equal (concat (expand-file-name "Attachments/diagram.png" root) "\n")
                   (vault-test--cli "path" "diagram.png")))
    (should (equal (vault-test--read v "Home.md") (vault-test--cli "read" "home")))
    (let ((err (should-error (vault-test--cli "path" "Trel") :type 'user-error)))
      (should (string-search "Close: Notes/Work/Trellis" (cadr err))))
    (should (string-search "aliases: Review, Weekly\ntags: gtd, routine\n"
                           (vault-test--cli "info" "Weekly Review")))))

(ert-deftest vault-test-cli-links ()
  (vault-test-with-vault
    (should (equal (concat "3: [[Weekly Review]] -> Weekly Review.md\n"
                           "3: [[Ongoing work]] -> Ongoing work.md\n"
                           "4: [[Follow-ups.base#Active]] -> Follow-ups.base\n"
                           "5: [[Notes/Work/Trellis]] -> Notes/Work/Trellis.md\n"
                           "6: [[Nowhere]] -> (no such note)\n")
                   (vault-test--cli "links" "Home")))
    (should (equal '("Day Notes/2026/08/Aug 7, 2026.md:3: [[Home]]"
                     "Ongoing work.md:1: See [[Home#Goals]] and [the review](Weekly%20Review.md)."
                     "Weekly Review.md:7: Back to [[Home]].")
                   (vault-test--cli-lines "backlinks" "Home")))
    (should (equal "Home.md:6: [[Nowhere]]\n" (vault-test--cli "unresolved")))
    (should (equal '("Day Notes/2026/08/Aug 14, 2026.md"
                     "Day Notes/2026/08/Aug 7, 2026.md" "Notes/Clojure.md")
                   (vault-test--cli-lines "orphans")))
    (should (equal '("Notes/Clojure.md")
                   (vault-test--cli-lines "orphans" "--folder" "Notes")))
    (should (equal '("Day Notes/2026/08/Aug 14, 2026.md" "Notes/Clojure.md")
                   (vault-test--cli-lines "deadends")))
    (should (equal '("gtd\t2" "routine\t1" "work\t1" "work/project\t1")
                   (vault-test--cli-lines "tags")))))

(ert-deftest vault-test-cli-tasks ()
  (vault-test-with-vault
    (make-directory (expand-file-name "Inbox" root))
    (write-region (concat "- [x] Done\n\n```\n- [ ] In a code block\n```\n"
                          "1. [ ] Numbered\n  * [/] Half done\n")
                  nil (expand-file-name "Inbox/Chores.md" root) nil 'silent)
    (should (equal '("Inbox/Chores.md:6: [ ] Numbered"
                     "Weekly Review.md:11: [ ] Empty the inbox")
                   (vault-test--cli-lines "tasks")))
    (should (equal "Inbox/Chores.md:1: [x] Done\nInbox/Chores.md:7: [x] Half done\n"
                   (vault-test--cli "tasks" "--done")))
    (should (equal 3 (length (vault-test--cli-lines "tasks" "Chores" "--all"))))
    (should (equal "Weekly Review.md:11: [ ] Empty the inbox\n"
                   (vault-test--cli "tasks" "--tag" "routine")))))

(ert-deftest vault-test-cli-daily ()
  (vault-test-with-vault
    (vault-test-at (0 30 8 14 8 2026 nil -1 nil)
      (let ((today (expand-file-name "Day Notes/2026/08/Aug 14, 2026.md" root))
            (tomorrow (expand-file-name "Day Notes/2026/08/Aug 15, 2026.md" root)))
        (should (equal (concat today "\n") (vault-test--cli "daily")))
        (should (equal "## Log\n" (vault-test--cli "daily" "today" "--read")))
        (should (equal "## Log\n\n[[Home]]\n"
                       (vault-test--cli "daily" "-7" "--read")))
        (should (equal "## Log\n\n[[Home]]\n"
                       (vault-test--cli "daily" "2026-08-07" "--read")))
        ;; --path and --read create nothing; plain `daily' does.
        (should (equal (concat tomorrow "\n")
                       (vault-test--cli "daily" "tomorrow" "--path")))
        (should-error (vault-test--cli "daily" "+1" "--read") :type 'user-error)
        (should-not (file-exists-p tomorrow))
        (should (equal (concat tomorrow "\n") (vault-test--cli "daily" "tomorrow")))
        (should (equal "## Log\n\nAug 15, 2026 on 2026-08-15\n"
                       (vault-test--read v "Day Notes/2026/08/Aug 15, 2026.md")))
        (should-error (vault-test--cli "daily" "someday")
                      :type 'vault-cli-usage)))))

(ert-deftest vault-test-cli-log ()
  (vault-test-with-vault
    (vault-test-at (0 30 8 14 8 2026 nil -1 nil)
      (vault-test--cli "log" "from" "an agent")
      (should (equal "## Log\n\n- 08:30 from an agent\n"
                     (vault-test--read v "Day Notes/2026/08/Aug 14, 2026.md"))))
    ;; A day with no note yet gets one from the template first.
    (vault-test-at (0 5 9 16 8 2026 nil -1 nil)
      (vault-test--cli "log" "new day")
      (should (equal "## Log\n\nAug 16, 2026 on 2026-08-16\n- 09:05 new day\n"
                     (vault-test--read v "Day Notes/2026/08/Aug 16, 2026.md"))))))

(ert-deftest vault-test-cli-new ()
  (vault-test-with-vault
    (vault-test-at (0 30 8 14 8 2026 nil -1 nil)
      (should (equal (concat (expand-file-name "Inbox/Idea.md" root) "\n")
                     (vault-test--cli "new" "Idea")))
      (should (equal "" (vault-test--read v "Inbox/Idea.md")))
      (should-error (vault-test--cli "new" "Idea") :type 'user-error)
      (cl-letf (((symbol-function 'vault-cli--stdin) (lambda () "From stdin\n")))
        (vault-test--cli "new" "Standup" "--folder" "Notes/Work" "--stdin"
                         "--template" "day note"))
      (should (equal "## Log\n\nStandup on 2026-08-14\nFrom stdin\n"
                     (vault-test--read v "Notes/Work/Standup.md")))
      (should-error (vault-test--cli "new" "X" "--template" "Missing")
                    :type 'user-error)
      (should-error (vault-test--cli "new" "../../escape") :type 'user-error))))

(ert-deftest vault-test-cli-set ()
  (vault-test-with-vault
    (vault-test--cli "set" "Home" "followup=active" "next_action=Call: the bank")
    (should (string-prefix-p
             "---\nfollowup: active\nnext_action: \"Call: the bank\"\n---\n# Home\n"
             (vault-test--read v "Home.md")))
    (should (equal "Home.md\tCall: the bank\n"
                   (vault-test--cli "list" "--where" "followup=active"
                                    "--show" "next_action")))
    (vault-test--cli "set" "Home" "followup=done")
    (should-not (vault-test--cli-lines "list" "--where" "followup=active"))
    (vault-test--cli "unset" "Weekly Review" "tags" "aliases")
    (should (string-prefix-p "---\n---\nBack to"
                             (vault-test--read v "Weekly Review.md")))
    (should-error (vault-test--cli "set" "Home" "no-equals-sign")
                  :type 'vault-cli-usage)))

(ert-deftest vault-test-cli-rename-and-trash ()
  (vault-test-with-vault
    ;; No slash: the note stays in its folder.
    (should (equal (concat (expand-file-name "Notes/Work/Lattice.md" root) "\n")
                   (vault-test--cli "rename" "Trellis" "Lattice")))
    (should (string-search "[[Notes/Work/Lattice]]" (vault-test--read v "Home.md")))
    ;; A slash: a path from the vault root.  A leading one is the root.
    (vault-test--cli "rename" "Lattice" "/Lattice")
    (should (file-exists-p (expand-file-name "Lattice.md" root)))
    (should (string-search "[[Lattice]]" (vault-test--read v "Home.md")))
    (should-error (vault-test--cli "rename" "Lattice" "Lattice")
                  :type 'user-error)
    (should-error (vault-test--cli "rename" "Lattice" "Home") :type 'user-error)
    ;; Trashing keeps what is already in the trash.
    (should (equal (concat (expand-file-name ".trash/Clojure.md" root) "\n")
                   (vault-test--cli "trash" "Notes/Clojure")))
    (should (equal (concat (expand-file-name ".trash/Clojure 2.md" root) "\n")
                   (vault-test--cli "trash" "Clojure")))
    (should-error (vault-test--cli "path" "Clojure") :type 'user-error)))

(ert-deftest vault-test-cli-choosing-the-vault ()
  (vault-test-with-vault
    (should (equal (concat (directory-file-name root) "\n")
                   (vault-test--cli "root")))
    (should (equal (concat (directory-file-name root) "\n")
                   (vault-test--cli "root" "--vault" root)))
    (should (equal (concat (directory-file-name root) "\n")
                   (vault-test--cli "--vault"
                                    (upcase (file-name-nondirectory
                                             (directory-file-name root)))
                                    "root")))
    (should-error (vault-test--cli "root" "--vault" "No such vault")
                  :type 'user-error)
    (should (string-prefix-p "* " (vault-test--cli "vaults")))
    (should (string-search "daily_format: YYYY/MM/MMM D, yyyy\n"
                           (vault-test--cli "config")))
    (should (string-search "new_note_folder: Inbox\n" (vault-test--cli "config")))))

(ert-deftest vault-test-cli-usage ()
  (vault-test-with-vault
    (should (string-prefix-p "notes: " (vault-test--cli)))
    (should (string-prefix-p "notes: " (vault-test--cli "list" "--help")))
    (dolist (args '(("nonsense") ("list" "--bogus") ("list" "extra")
                    ("path") ("backlinks" "Home" "--folder" "Notes")
                    ("list" "--limit" "many") ("list" "--folder")))
      (should-error (apply #'vault-test--cli args) :type 'vault-cli-usage))
    ;; Only words starting with -- are options, and a lone -- ends them.
    (should (equal '(nil "-7" "--x")
                   (vault-cli--parse '("-7" "--" "--x"))))
    (should (equal '((("--where" "b" "a") ("--json" . t) ("--tag" . "x")) "list")
                   (vault-cli--parse
                    '("list" "--tag=x" "--json" "--where" "a" "--where" "b"))))))

;;; vault-test.el ends here
