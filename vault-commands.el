;;; vault-commands.el --- Navigating and creating notes -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive side of vault.el: the note switcher, following and
;; inserting links, daily notes, templates, capture, search and tags.

;;; Code:

(require 'vault)

(declare-function consult--read "consult")
(declare-function consult--file-preview "consult")
(declare-function consult-ripgrep "consult")
(declare-function evil-set-jump "evil-jumps")
(declare-function org-read-date "org")

(defcustom vault-log-heading "Log"
  "Heading in the daily note under which `vault-log' files its entries."
  :type 'string :group 'vault)

(defcustom vault-home-note "Home"
  "Name of the note `vault-home' opens."
  :type 'string :group 'vault)

(defcustom vault-file-extensions
  '("png" "jpg" "jpeg" "gif" "svg" "webp" "pdf" "base" "canvas" "csv"
    "mp3" "mp4" "mov" "wav")
  "Extensions that mark a link target as a file, not a note to create."
  :type '(repeat string) :group 'vault)

(defvar vault--history nil "Minibuffer history for note names.")

;;; Opening notes

(defun vault--now ()
  "Return the current time.  A function so that tests can pin the clock."
  (current-time))

(defun vault--file-buffer (path)
  "Return a buffer visiting PATH.
Emacs opens a file read-only when its folder is missing.  A new note is
made writable instead, and its folder is created by the first save."
  ;; Asking `find-file-noselect' again for a new note in a missing folder
  ;; makes it offer to turn the buffer read-only, so reuse the buffer.
  (let ((buffer (or (find-buffer-visiting path) (find-file-noselect path))))
    (unless (file-exists-p path)
      (with-current-buffer buffer
        (setq buffer-read-only nil)
        (add-hook 'before-save-hook #'vault-ensure-directory nil t)))
    buffer))

(defun vault-ensure-directory ()
  "Create the directory of the current buffer's file if it is missing.
New notes are plain unsaved buffers, so their folder may not exist until
the first save."
  (when buffer-file-name
    (make-directory (file-name-directory buffer-file-name) t)))

(defun vault--new-note-directory (vault)
  "Return the directory in which VAULT creates new notes."
  (cond ((vault-setting vault :new-note-folder)
         (expand-file-name (vault-setting vault :new-note-folder)
                           (vault--root vault)))
        ((and (vault-setting vault :new-note-current) buffer-file-name
              (equal (vault-root-for buffer-file-name) (vault--root vault)))
         (file-name-directory buffer-file-name))
        (t (vault--root vault))))

(defun vault--new-note-path (vault name)
  "Return the path VAULT gives a new note called NAME.
A NAME with a folder in it is taken relative to the vault root."
  (let ((name (string-remove-suffix ".md" (string-trim name))))
    (concat (if (string-search "/" name)
                (expand-file-name name (vault--root vault))
              (expand-file-name name (vault--new-note-directory vault)))
            ".md")))

(defun vault--goto-heading (heading)
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

(defun vault--visit (path &optional heading other-window)
  "Visit PATH, remembering where we came from, then go to HEADING."
  (when (fboundp 'evil-set-jump) (evil-set-jump))
  (let ((buffer (vault--file-buffer path)))
    (if other-window
        (switch-to-buffer-other-window buffer)
      (pop-to-buffer-same-window buffer)))
  (vault--goto-heading heading))

(defun vault-open (vault target &optional heading from other-window)
  "Open what link TARGET means in VAULT: a note, a file, or a new note.
HEADING is a heading or ^block to land on and FROM the note holding the link."
  (if-let* ((note (vault-resolve vault target from)))
      (vault--visit (vault-note-path note) heading other-window)
    (if-let* ((file (vault-resolve-file vault target)))
        (vault--visit file nil other-window)
      (when (member (downcase (or (file-name-extension target) ""))
                    vault-file-extensions)
        (user-error "No file called %s in this vault" target))
      (vault--visit (vault--new-note-path vault target) nil other-window)
      (message "New note: %s (save to create it)" target))))

;;; Choosing a note

(defun vault--candidates (vault notes)
  "Return an alist of display string to (NOTE . ALIAS) for NOTES in VAULT.
Notes that share a name are told apart by folder.  Each alias is offered
as a candidate of its own."
  (let (result)
    (dolist (note notes)
      (let* ((name (vault-note-name note))
             (dup (cdr (gethash (downcase name) (vault--names vault)))))
        (push (cons (if dup
                        (format "%s  (%s)" name
                                (directory-file-name
                                 (or (file-name-directory (vault-note-rel note))
                                     "/")))
                      name)
                    (cons note nil))
              result)
        (dolist (alias (vault-note-aliases note))
          (push (cons (format "%s  → %s" alias name) (cons note alias))
                result))))
    (nreverse result)))

(defun vault--annotate (candidates)
  "Return a function annotating CANDIDATES with folder, tags and age."
  (lambda (cand)
    (when-let* ((note (cadr (assoc cand candidates))))
      (concat
       (propertize " " 'display '(space :align-to 52))
       (propertize (format "%-28s"
                           (truncate-string-to-width
                            (or (file-name-directory (vault-note-rel note)) "")
                            28 nil nil t))
                   'face 'completions-annotations)
       (propertize (format "%-10s" (format-time-string
                                    "%b %e %Y" (vault-note-mtime note)))
                   'face 'shadow)
       (propertize (mapconcat (lambda (tag) (concat " #" tag))
                              (vault-note-tags note))
                   'face 'font-lock-keyword-face)))))

(defun vault--main-window ()
  "Return the window notes are read and previewed in.
That is the selected window, unless it is a side window such as the
folder tree, when it is the ordinary window used last."
  (or (and (window-parameter nil 'window-side) (get-mru-window nil nil t))
      (selected-window)))

(defun vault-read-note (prompt vault &optional notes require-match)
  "Read a note from VAULT with PROMPT, previewing candidates as they change.
NOTES narrows the choice.  Return (NOTE . ALIAS) for an existing note, with
ALIAS non-nil if it was picked by alias, or the typed string for a new one."
  (let* ((candidates (vault--candidates vault (or notes (vault-notes vault))))
         (lookup (lambda (selected &rest _)
                   (or (cdr (assoc selected candidates)) selected))))
    ;; The preview takes over the window the read started in, which should
    ;; not be the tree or the panel.
    (with-selected-window (vault--main-window)
      (if (require 'consult nil t)
          (let ((preview (consult--file-preview)))
            (consult--read
             candidates
             :prompt prompt :sort nil :require-match require-match
             :category 'vault-note :history 'vault--history
             :annotate (vault--annotate candidates)
             :lookup lookup
             :state (lambda (action cand)
                      (funcall preview action
                               (and (consp cand)
                                    (vault-note-path (car cand)))))))
        (let ((completion-extra-properties
               (list :annotation-function (vault--annotate candidates))))
          (funcall lookup (completing-read prompt candidates nil require-match
                                           nil 'vault--history)))))))

;;;###autoload
(defun vault-find (&optional other-window)
  "Jump to a note, or create one if the name typed matches nothing.
With a prefix argument, open it in the OTHER-WINDOW."
  (interactive "P")
  (vault--find (vault-current) other-window))

(defun vault--find (vault &optional other-window)
  "Read a note in VAULT and visit it, in the OTHER-WINDOW if non-nil."
  (let ((choice (vault-read-note "Note: " vault)))
    (if (consp choice)
        (vault--visit (vault-note-path (car choice)) nil other-window)
      (vault-open vault choice nil nil other-window))))

;;;###autoload
(defun vault-home ()
  "Open the vault's home note."
  (interactive)
  (vault-open (vault-current) vault-home-note))

;;;###autoload
(defun vault-random ()
  "Open a note picked at random."
  (interactive)
  (vault--visit (vault-note-path (seq-random-elt
                                  (vault-notes (vault-current))))))

;;;###autoload
(defun vault-switch ()
  "Make another vault the default and pick a note in it."
  (interactive)
  (let* ((roots (mapcar (lambda (root)
                          (cons (file-name-nondirectory
                                 (directory-file-name root))
                                root))
                        (vault-roots)))
         (name (completing-read "Vault: " roots nil t)))
    (setq vault-default-root (cdr (assoc name roots)))
    (vault--find (vault-get vault-default-root))))

;;; Links

(defun vault-link-at-point ()
  "Return (LINK BEG END) for the link around point, or nil."
  (save-excursion
    (let ((pos (point)) (eol (pos-eol)) found)
      (goto-char (pos-bol))
      (while (and (not found) (re-search-forward vault--link-regexp eol t))
        (when (and (<= (match-beginning 0) pos) (< pos (match-end 0)))
          (when-let* ((link (vault--match-link)))
            (setq found (list link (match-beginning 0) (match-end 0))))))
      found)))

(defun vault-toggle-checkbox ()
  "Tick or untick the task on the current line.  Return non-nil if it had one."
  (interactive)
  (save-excursion
    (goto-char (pos-bol))
    (when (looking-at "[ \t]*\\(?:[-*+]\\|[0-9]+[.)]\\)[ \t]+\\[\\(.\\)\\]")
      (replace-match (if (equal (match-string 1) " ") "x" " ") t t nil 1)
      t)))

;;;###autoload
(defun vault-follow (&optional other-window)
  "Follow the link at point, or tick the checkbox on this line.
A link to a note that does not exist yet starts that note.  Return nil if
there was nothing here to act on.  With a prefix argument, use the
OTHER-WINDOW."
  (interactive "P")
  (let ((vault (vault-current)))
    (cond
     ((when-let* ((found (vault-link-at-point))
                  (link (car found)))
        (vault-open vault (vault-link-target link) (vault-link-heading link)
                    (vault-note-at vault buffer-file-name) other-window)
        t))
     ((vault-toggle-checkbox))
     ((when-let* ((url (thing-at-point 'url)))
        (browse-url url)
        t)))))

;;;###autoload
(defun vault-follow-other-window ()
  "Follow the link at point in another window."
  (interactive)
  (vault-follow t))

(defun vault--link-text (vault choice &optional alias)
  "Return wikilink text for CHOICE from `vault-read-note', shown as ALIAS."
  (let* ((from (vault-note-at vault buffer-file-name))
         (target (if (consp choice)
                     (vault-link-name vault (car choice) from)
                   choice))
         (alias (or alias (and (consp choice) (cdr choice)))))
    (if (and alias (not (string-empty-p alias)) (not (equal alias target)))
        (format "[[%s|%s]]" target alias)
      (format "[[%s]]" target))))

;;;###autoload
(defun vault-insert-link ()
  "Insert a link to a note.  An active region becomes the link's text."
  (interactive)
  (let* ((vault (vault-current))
         (region (and (use-region-p)
                      (buffer-substring-no-properties
                       (region-beginning) (region-end))))
         (choice (vault-read-note "Link to: " vault)))
    (when region (delete-region (region-beginning) (region-end)))
    (insert (vault--link-text vault choice region))))

(defun vault--next-link (count)
  "Move to the COUNTth link after point, or before it if COUNT is negative."
  (let ((start (point)))
    (if (> count 0)
        (progn (when-let* ((here (vault-link-at-point)))
                 (goto-char (nth 2 here)))
               (if (re-search-forward vault--link-regexp nil t count)
                   (goto-char (match-beginning 0))
                 (goto-char start)
                 (user-error "No more links")))
      (unless (re-search-backward vault--link-regexp nil t (- count))
        (user-error "No more links")))))

(defun vault-next-link (&optional count)
  "Move to the next link, or the COUNTth."
  (interactive "p")
  (vault--next-link (or count 1)))

(defun vault-previous-link (&optional count)
  "Move to the previous link, or the COUNTth."
  (interactive "p")
  (vault--next-link (- (or count 1))))

;;; Templates

(defun vault--expand-template (text title time)
  "Fill Obsidian's {{title}}, {{date}} and {{time}} variables in TEXT."
  (replace-regexp-in-string
   "{{\\(title\\|date\\|time\\)\\(?::\\([^}]*\\)\\)?}}"
   (lambda (match)
     (let ((kind (match-string 1 match))
           (format (match-string 2 match)))
       (pcase kind
         ("title" title)
         ("date" (vault-format-date (or format "YYYY-MM-DD") time))
         ("time" (vault-format-date (or format "HH:mm") time)))))
   text t t))

(defun vault--template-text (vault name title time)
  "Return template NAME from VAULT expanded for TITLE and TIME, or nil."
  (when-let* ((note (and name (vault-resolve vault name))))
    (with-temp-buffer
      (insert-file-contents (vault-note-path note))
      (vault--expand-template (buffer-string) title time))))

;;;###autoload
(defun vault-insert-template ()
  "Insert one of the vault's templates at point."
  (interactive)
  (let* ((vault (vault-current))
         (folder (or (vault-setting vault :template-folder)
                     (user-error "This vault has no template folder")))
         (prefix (downcase (file-name-as-directory folder)))
         (templates (cl-remove-if-not
                     (lambda (note)
                       (string-prefix-p prefix (downcase (vault-note-rel note))))
                     (vault-notes vault)))
         (choice (vault-read-note "Template: " vault templates t)))
    (insert (vault--template-text
             vault (vault-note-rel (car choice))
             (if buffer-file-name (file-name-base buffer-file-name) "")
             (vault--now)))))

;;; Daily notes

(defun vault--daily-buffer (vault time)
  "Return a buffer on VAULT's daily note for TIME, filled in if it is new."
  (let* ((path (vault-daily-path vault time))
         (buffer (vault--file-buffer path)))
    (with-current-buffer buffer
      (when (and (not (file-exists-p path)) (zerop (buffer-size)))
        (when-let* ((text (vault--template-text
                           vault (vault-setting vault :daily-template)
                           (file-name-base path) time)))
          (insert text)
          (goto-char (point-min)))))
    buffer))

;;;###autoload
(defun vault-daily (&optional time)
  "Open the daily note for TIME, today by default."
  (interactive)
  (when (fboundp 'evil-set-jump) (evil-set-jump))
  (switch-to-buffer (vault--daily-buffer (vault-current) (or time (vault--now)))))

(defun vault--days-from-now (days)
  "Return the time DAYS days from now."
  (time-add (vault--now) (days-to-time days)))

;;;###autoload
(defun vault-daily-yesterday ()
  "Open yesterday's daily note."
  (interactive)
  (vault-daily (vault--days-from-now -1)))

;;;###autoload
(defun vault-daily-tomorrow ()
  "Open tomorrow's daily note."
  (interactive)
  (vault-daily (vault--days-from-now 1)))

;;;###autoload
(defun vault-daily-date ()
  "Open the daily note for a date picked from the calendar."
  (interactive)
  (require 'org)
  (vault-daily (org-read-date nil t nil "Daily note for: ")))

(defun vault--daily-notes (vault)
  "Return (TIME . PATH) for VAULT's existing daily notes, oldest first.
Looks fifteen years back and one ahead."
  (cl-loop for offset from (* -15 366) to 366
           for time = (vault--days-from-now offset)
           for path = (vault-daily-path vault time)
           when (gethash path (vault--notes vault))
           collect (cons time path)))

(defun vault--daily-step (direction)
  "Open the nearest daily note after this one, or before if DIRECTION is -1."
  (let* ((vault (vault-current))
         (dailies (vault--daily-notes vault))
         (here (or (car (rassoc buffer-file-name dailies)) (vault--now)))
         (later (lambda (entry) (time-less-p here (car entry))))
         (earlier (lambda (entry) (time-less-p (car entry) here)))
         (hit (if (> direction 0)
                  (cl-find-if later dailies)
                (cl-find-if earlier dailies :from-end t))))
    (if hit
        (vault--visit (cdr hit))
      (user-error "No %s daily note" (if (> direction 0) "later" "earlier")))))

;;;###autoload
(defun vault-daily-next ()
  "Open the next daily note that exists."
  (interactive)
  (vault--daily-step 1))

;;;###autoload
(defun vault-daily-previous ()
  "Open the previous daily note that exists."
  (interactive)
  (vault--daily-step -1))

;;; Capture

;;;###autoload
(defun vault-capture (title)
  "Start a new note called TITLE where the vault keeps new notes."
  (interactive "sNew note: ")
  (let ((vault (vault-current)))
    (when (string-empty-p (string-trim title))
      (user-error "A note needs a name"))
    (vault--visit (vault--new-note-path vault title))))

(defun vault--insert-log-entry (text time)
  "File TEXT, stamped with TIME, under the log heading of the current buffer.
The entry goes at the end of that section, or at the end of the note if
it has no such heading."
  (let ((entry (format "- %s %s" (format-time-string "%H:%M" time) text)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (if (re-search-forward
             (format "^#+[ \t]+%s[ \t]*$" (regexp-quote vault-log-heading))
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
(defun vault-log (text)
  "File TEXT, with the time, under the log heading of today's daily note.
The note is saved and stays in the background."
  (interactive "sLog: ")
  (let* ((vault (vault-current))
         (now (vault--now))
         (buffer (vault--daily-buffer vault now)))
    (with-current-buffer buffer
      (vault--insert-log-entry text now)
      (vault-ensure-directory)
      (let ((save-silently t)) (save-buffer)))
    (message "Logged to %s" (file-name-base (buffer-file-name buffer)))))

;;; Search and tags

;;;###autoload
(defun vault-search (&optional initial)
  "Search the text of every note, starting from INITIAL."
  (interactive)
  (consult-ripgrep (vault--root (vault-current)) initial))

(defun vault-tags (vault &optional notes)
  "Return an alist of tag to the notes in VAULT carrying it.
A nested tag such as a/b also counts towards a.  NOTES, if given, are the
only notes looked at."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (note (or notes (vault-notes vault)))
      (dolist (tag (vault-note-tags note))
        (let ((parts (split-string tag "/" t)) prefix)
          (dolist (part parts)
            (setq prefix (if prefix (concat prefix "/" part) part))
            (cl-pushnew note (gethash prefix table))))))
    (sort (cl-loop for tag being the hash-keys of table using (hash-values notes)
                   collect (cons tag (nreverse notes)))
          (lambda (a b) (string< (car a) (car b))))))

;;;###autoload
(defun vault-find-by-tag ()
  "Pick a tag, then one of the notes carrying it."
  (interactive)
  (let* ((vault (vault-current))
         (tags (or (vault-tags vault) (user-error "No tags in this vault")))
         (completion-extra-properties
          (list :annotation-function
                (lambda (tag) (format "  %d" (length (cdr (assoc tag tags)))))))
         (tag (completing-read "Tag: " tags nil t))
         (choice (vault-read-note (format "#%s: " tag) vault
                                  (cdr (assoc tag tags)) t)))
    (vault--visit (vault-note-path (car choice)))))

;;;###autoload
(defun vault-open-in-obsidian ()
  "Open the current note in the Obsidian app."
  (interactive)
  (unless buffer-file-name (user-error "This buffer has no file"))
  (call-process "open" nil 0 nil
                (concat "obsidian://open?path="
                        (url-hexify-string buffer-file-name))))

(provide 'vault-commands)
;;; vault-commands.el ends here
