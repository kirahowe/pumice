;;; vault-ui.el --- Note buffers and the backlinks panel -*- lexical-binding: t; -*-

;;; Commentary:

;; `vault-mode' is a minor mode for note buffers: it colours wikilinks by
;; whether they resolve, completes note names, headings and tags, and keeps
;; the index current as notes are saved.  `vault-panel-toggle' shows a side
;; window that follows the current note with its backlinks, the places
;; that mention it without linking, and its outgoing links.

;;; Code:

(require 'vault)
(require 'vault-commands)
(require 'vault-refactor)

(declare-function markdown-code-block-at-pos "markdown-mode")
(declare-function ispell-completion-at-point "ispell")
(defvar corfu-auto-prefix)

(defface vault-link '((t :inherit link :underline nil))
  "A link to a note or file that exists." :group 'vault)
(defface vault-link-unresolved '((t :inherit shadow :underline t))
  "A link to a note that has not been written yet." :group 'vault)
(defface vault-markup '((t :inherit shadow))
  "Link brackets, and the target of a link that shows other text."
  :group 'vault)
(defface vault-tag '((t :inherit font-lock-constant-face))
  "A #tag." :group 'vault)
(defface vault-panel-heading '((t :inherit bold :height 1.0))
  "Section titles in the backlinks panel." :group 'vault)

;;; Highlighting

(defvar-keymap vault-link-map
  :doc "Keys active on a link."
  "<mouse-2>" #'vault-follow-mouse
  "<follow-link>" 'mouse-face)

(defun vault-follow-mouse (event)
  "Follow the link clicked on in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (vault-follow))

(defconst vault--wikilink-regexp
  "\\(!?\\[\\[\\)\\([^]\n|]*\\)\\(?:\\(|\\)\\([^]\n]*\\)\\)?\\(\\]\\]\\)"
  "A wikilink split for highlighting: open, target, bar, alias, close.")

(defun vault--in-code-p (pos)
  "Non-nil if POS is inside a Markdown code block."
  (and (derived-mode-p 'markdown-mode)
       (fboundp 'markdown-code-block-at-pos)
       (save-match-data (markdown-code-block-at-pos pos))))

(defun vault--match-outside-code (regexp limit)
  "Search for REGEXP up to LIMIT, skipping matches inside code blocks."
  (let (found)
    (while (and (not found) (re-search-forward regexp limit t))
      (unless (vault--in-code-p (match-beginning 0))
        (setq found t)))
    found))

(defun vault--link-props ()
  "Return text properties for the wikilink just matched."
  (let* ((text (match-string-no-properties 2))
         (resolved
          (save-match-data
            (let ((vault (vault-current t))
                  (target (car (split-string text "#"))))
              (or (vault-resolve vault target
                                 (vault-note-at vault buffer-file-name))
                  (vault-resolve-file vault target))))))
    (list 'face (if resolved 'vault-link 'vault-link-unresolved)
          'mouse-face 'highlight 'keymap vault-link-map
          'help-echo "RET or mouse-1: follow this link")))

(defconst vault--font-lock-keywords
  `((,(lambda (limit) (vault--match-outside-code vault--wikilink-regexp limit))
     (1 'vault-markup t)
     (2 (if (match-beginning 3) 'vault-markup (vault--link-props)) t)
     (3 'vault-markup t t)
     (4 (vault--link-props) t t)
     (5 'vault-markup t))
    (,(lambda (limit)
        (vault--match-outside-code
         "\\(?:^\\|[ \t(]\\)\\(#[[:alpha:]_][[:alnum:]_/-]*\\)" limit))
     (1 'vault-tag t))
    ("%%.*?%%" (0 'font-lock-comment-face t)))
  "Highlighting for wikilinks, tags and Obsidian %% comments %%.")

;;; Completion

(defun vault-note-headings (note)
  "Return the headings in NOTE, in order."
  (with-temp-buffer
    (insert-file-contents (vault-note-path note))
    (cl-loop while (re-search-forward "^#+[ \t]+\\(.*?\\)[ \t]*$" nil t)
             collect (match-string-no-properties 1))))

(defun vault--link-candidates (vault from)
  "Return link targets for every note in VAULT as seen from note FROM.
An alias is offered as Target|Alias, ready to insert."
  (cl-loop for note in (vault-notes vault)
           for target = (vault-link-name vault note from)
           collect (propertize target 'vault-note note)
           append (mapcar (lambda (alias)
                            (propertize (concat target "|" alias)
                                        'vault-note note))
                          (vault-note-aliases note))))

(defun vault--unsorted-table (candidates)
  "Return a completion table over CANDIDATES that keeps their order.
Notes arrive most recently edited first, which is the order wanted."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun vault-completion-at-point ()
  "Complete a note name after [[, a heading after [[Note#, or a #tag."
  (let* ((bol (pos-bol))
         (vault (vault-current t))
         (from (vault-note-at vault buffer-file-name)))
    (cond
     ((looking-back "\\[\\[\\([^]\n|#]*\\)\\(?:#\\([^]\n|]*\\)\\)?" bol)
      (let ((close (lambda (_ status)
                     (when (and (eq status 'finished) (not (looking-at-p "\\]\\]")))
                       (insert "]]")))))
        (if (match-beginning 2)
            (when-let* ((note (vault-resolve vault (match-string 1) from)))
              (list (match-beginning 2) (point) (vault-note-headings note)
                    :exclusive 'no :exit-function close))
          (list (match-beginning 1) (point)
                (vault--unsorted-table (vault--link-candidates vault from))
                :exclusive 'no :exit-function close
                :annotation-function
                (lambda (cand)
                  (when-let* ((note (get-text-property 0 'vault-note cand))
                              (dir (file-name-directory (vault-note-rel note))))
                    (unless (string-search "/" cand)
                      (concat "  " dir))))))))
     ((looking-back "\\(?:^\\|[ \t(]\\)#\\([[:alpha:]_][[:alnum:]_/-]*\\)" bol)
      (list (match-beginning 1) (point) (mapcar #'car (vault-tags vault))
            :exclusive 'no)))))

;;; The minor mode

(defun vault--after-save ()
  "Reindex after a save so links and the panel reflect it at once."
  (vault-refresh (vault-current t) t)
  (font-lock-flush))

(defvar-keymap vault-mode-map
  :doc "Keys for note buffers.  The vim bindings are set up in init.el.")

;;;###autoload
(define-minor-mode vault-mode
  "Minor mode for a note that lives in a vault."
  :lighter " Vault"
  (if vault-mode
      (progn
        (font-lock-add-keywords nil vault--font-lock-keywords 'append)
        (make-local-variable 'font-lock-extra-managed-props)
        (dolist (prop '(mouse-face keymap help-echo))
          (cl-pushnew prop font-lock-extra-managed-props))
        (add-hook 'completion-at-point-functions
                  #'vault-completion-at-point nil t)
        ;; Dictionary completion would pop up on every word of prose.
        (remove-hook 'completion-at-point-functions
                     #'ispell-completion-at-point t)
        ;; Offer notes as soon as [[ is typed.
        (setq-local corfu-auto-prefix 0)
        (add-hook 'after-save-hook #'vault--after-save nil t)
        (add-hook 'before-save-hook #'vault-ensure-directory nil t)
        (visual-line-mode 1))
    (font-lock-remove-keywords nil vault--font-lock-keywords)
    (remove-hook 'completion-at-point-functions #'vault-completion-at-point t)
    (kill-local-variable 'corfu-auto-prefix)
    (remove-hook 'after-save-hook #'vault--after-save t)
    (remove-hook 'before-save-hook #'vault-ensure-directory t))
  (font-lock-flush))

;;;###autoload
(defun vault-mode-maybe ()
  "Turn on `vault-mode' if this buffer is a Markdown file in a vault."
  (when (and buffer-file-name
             (string-suffix-p ".md" buffer-file-name t)
             (vault-root-for buffer-file-name))
    (vault-mode 1)))

;;;###autoload
(define-minor-mode vault-global-mode
  "Turn on `vault-mode' in every Markdown file opened from a vault."
  :global t :group 'vault
  (if vault-global-mode
      (add-hook 'find-file-hook #'vault-mode-maybe)
    (remove-hook 'find-file-hook #'vault-mode-maybe)))

;;; Unlinked mentions

(defun vault-unlinked-mentions (vault note)
  "Return (PATH LINE TEXT) for lines in VAULT naming NOTE without linking.
Needs ripgrep; returns nil without it."
  (let ((names (cl-remove-if (lambda (name) (< (length name) 3))
                             (cons (vault-note-name note)
                                   (vault-note-aliases note))))
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
                                           (vault--root vault)))))
         when (and (string-match "\\`\\(.*?\\.md\\):\\([0-9]+\\):\\(.*\\)\\'"
                                 line)
                   (not (equal (match-string 1 line) (vault-note-path note)))
                   (not (string-match-p linked (match-string 3 line))))
         collect (list (match-string 1 line)
                       (string-to-number (match-string 2 line))
                       (string-trim (match-string 3 line))))))))

(defun vault-link-mention (path line note)
  "Turn the first plain mention of NOTE on LINE of PATH into a link."
  (let* ((vault (vault-get (vault-root-for path)))
         (names (cons (vault-note-name note) (vault-note-aliases note)))
         (target (vault-link-name vault note (vault-note-at vault path)))
         (case-fold-search t) done)
    (vault--edit-file
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
    (vault-refresh vault t)
    done))

;;; Side windows

;; The backlinks panel and the folder tree sit in side windows.  Anything
;; opened while one of them is selected belongs in the main window.  Left
;; alone, Emacs would split the main window for `find-file', and
;; `switch-to-buffer' would put its buffer in the narrow side window.

(define-derived-mode vault-side-mode special-mode "Vault"
  "Parent of the modes shown in side windows: the panel and the tree."
  (setq truncate-lines t
        cursor-in-non-selected-windows nil)
  ;; The windows are strongly dedicated.  `switch-to-buffer' called from
  ;; Lisp pops to another window when it meets one, but typed as a command
  ;; it refuses to run unless told to pop as well.
  (setq-local switch-to-buffer-in-dedicated-window 'pop))

(defun vault--side-window-selected-p (&rest _)
  "Non-nil if the selected window shows the panel or the tree."
  (with-current-buffer (window-buffer)
    (derived-mode-p 'vault-side-mode)))

(add-to-list 'display-buffer-alist
             '(vault--side-window-selected-p
               (display-buffer-reuse-window display-buffer-use-some-window)
               (some-window . mru)))

(defun vault--show-side-window (buffer side width)
  "Show BUFFER in a window WIDTH columns wide on SIDE of the frame."
  (display-buffer-in-side-window
   buffer
   `((side . ,side) (window-width . ,width)
     (dedicated . t) (preserve-size . (t . nil))
     (window-parameters (no-delete-other-windows . t)))))

;;; Backlinks panel

(defconst vault-panel-buffer "*vault*" "Name of the panel buffer.")

(defcustom vault-panel-width 44
  "Width of the backlinks panel in columns."
  :type 'integer :group 'vault)

(defvar-local vault-panel--shown nil "What the panel last drew: (PATH . TICK).")
(defvar vault-panel--timer nil)

(defvar-keymap vault-panel-mode-map
  :doc "Keys in the backlinks panel."
  "RET" #'vault-panel-visit
  "o" #'vault-panel-peek
  "l" #'vault-panel-link-mention
  "TAB" #'vault-panel-next
  "n" #'vault-panel-next
  "<backtab>" #'vault-panel-previous
  "p" #'vault-panel-previous
  "g" #'vault-panel-refresh
  "q" #'vault-panel-toggle)

(define-derived-mode vault-panel-mode vault-side-mode "Vault"
  "Backlinks, unlinked mentions and outgoing links of the current note.")

(defun vault-panel--context (text)
  "Return context line TEXT with its links picked out."
  (let ((text (propertize (copy-sequence text) 'face 'shadow)) (start 0))
    (while (string-match "\\[\\[[^]\n]*\\]\\]" text start)
      (put-text-property (match-beginning 0) (match-end 0) 'face 'vault-link text)
      (setq start (match-end 0)))
    text))

(defun vault-panel--section (title groups)
  "Insert a section called TITLE.
GROUPS is a list of (LABEL ITEM FACE . LINES) where LINES are (ITEM . TEXT)
pairs shown under the label.  ITEM is what RET on that line acts on."
  (insert (propertize (format "%s  %d\n" title
                              (if (cl-some #'cdddr groups)
                                  (cl-loop for g in groups sum (length (cdddr g)))
                                (length groups)))
                      'face 'vault-panel-heading))
  (pcase-dolist (`(,label ,item ,face . ,lines) groups)
    (insert (propertize (concat "  " label "\n") 'face face 'vault-item item))
    (pcase-dolist (`(,line-item . ,text) lines)
      (insert (propertize (concat "    " (vault-panel--context text) "\n")
                          'vault-item line-item))))
  (insert "\n"))

(defun vault-panel--group (entries)
  "Group ENTRIES, a list of (PATH LINE TEXT), into panel groups by file."
  (mapcar (lambda (group)
            (let ((path (car group)))
              `(,(file-name-base path) (:path ,path) vault-link
                ,@(mapcar (lambda (entry)
                            (cons (list :path path :line (nth 1 entry))
                                  (nth 2 entry)))
                          (cdr group)))))
          (seq-group-by #'car entries)))

(defun vault-panel--render (vault note)
  "Draw the panel for NOTE in VAULT."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (same (equal (car vault-panel--shown) (vault-note-path note))))
    (erase-buffer)
    (insert (propertize (vault-note-name note) 'face '(:inherit bold :height 1.2))
            "\n"
            (propertize (concat (or (file-name-directory (vault-note-rel note)) "")
                                (mapconcat (lambda (tag) (concat " #" tag))
                                           (vault-note-tags note)))
                        'face 'shadow)
            "\n\n")
    (vault-panel--section
     "Backlinks"
     (vault-panel--group
      (mapcar (lambda (pair)
                (list (vault-note-path (car pair))
                      (vault-link-line (cdr pair)) (vault-link-text (cdr pair))))
              (vault-backlinks vault note))))
    (vault-panel--section
     "Unlinked mentions"
     (mapcar (lambda (group)
               (dolist (line (cdddr group))
                 (setcar line (append (car line) (list :mention note))))
               group)
             (vault-panel--group (vault-unlinked-mentions vault note))))
    (vault-panel--section
     "Links"
     (cl-loop for target in (delete-dups
                             (mapcar #'vault-link-target (vault-note-links note)))
              for dest = (vault-resolve vault target note)
              for file = (and (not dest) (vault-resolve-file vault target))
              unless (string-empty-p target)
              collect (cond (dest (list (vault-note-name dest)
                                        (list :path (vault-note-path dest))
                                        'vault-link))
                            (file (list target (list :path file) 'vault-link))
                            (t (list target (list :new target)
                                     'vault-link-unresolved)))))
    (setq vault-local-root (vault--root vault)
          vault-panel--shown (cons (vault-note-path note) (vault--tick vault)))
    (goto-char (point-min))
    (when same (forward-line (1- line)))))

(defun vault-panel--sync (&optional force)
  "Point the panel at the selected window's note if that changed.
With FORCE, redraw even if nothing seems to have."
  (let ((panel (get-buffer vault-panel-buffer)))
    (if (not (and panel (get-buffer-window panel t)))
        (when vault-panel--timer
          (cancel-timer vault-panel--timer)
          (setq vault-panel--timer nil))
      (let ((path (buffer-file-name (window-buffer (selected-window)))))
        (when-let* ((root (and path (vault-root-for path)))
                    (vault (vault-get root))
                    (note (vault-note-at vault path)))
          (with-current-buffer panel
            (when (or force
                      (not (equal vault-panel--shown
                                  (cons path (vault--tick vault)))))
              (let ((window (get-buffer-window panel t)))
                (vault-panel--render vault note)
                (set-window-point window (point))))))))))

;;;###autoload
(defun vault-panel-toggle ()
  "Show or hide the backlinks panel beside the current note."
  (interactive)
  (if-let* ((window (get-buffer-window vault-panel-buffer)))
      (delete-window window)
    (with-current-buffer (get-buffer-create vault-panel-buffer)
      (unless (derived-mode-p 'vault-panel-mode) (vault-panel-mode))
      (vault--show-side-window (current-buffer) 'right vault-panel-width))
    (unless vault-panel--timer
      (setq vault-panel--timer
            (run-with-idle-timer 0.2 t #'vault-panel--sync)))
    (vault-panel--sync t)))

;;;###autoload
(defun vault-panel-focus ()
  "Move to the backlinks panel, opening it if needed."
  (interactive)
  (unless (get-buffer-window vault-panel-buffer) (vault-panel-toggle))
  (select-window (get-buffer-window vault-panel-buffer)))

(defun vault-panel-refresh ()
  "Redraw the panel from disk."
  (interactive)
  (when vault-local-root (vault-refresh (vault-get vault-local-root t) t))
  (setq vault-panel--shown nil)
  (when-let* ((window (get-mru-window nil nil t)))
    (with-selected-window window (vault-panel--sync t))))

(defun vault-panel--move (direction)
  "Move to the next panel item, or the previous if DIRECTION is -1."
  (let ((pos (point)) found)
    (while (and (not found) (zerop (forward-line direction)) (not (eobp)))
      (setq found (get-text-property (point) 'vault-item)))
    (unless found (goto-char pos))))

(defun vault-panel-next ()
  "Move to the next item."
  (interactive)
  (vault-panel--move 1))

(defun vault-panel-previous ()
  "Move to the previous item."
  (interactive)
  (vault-panel--move -1))

(defun vault-panel--open (item root)
  "Show ITEM from the vault at ROOT in the last used ordinary window."
  (select-window (or (get-mru-window nil nil t) (next-window)))
  (if-let* ((target (plist-get item :new)))
      (vault-open (vault-get root) target)
    (vault--visit (plist-get item :path))
    (when-let* ((line (plist-get item :line)))
      (goto-char (point-min))
      (forward-line (1- line))
      (recenter))))

(defun vault-panel-visit ()
  "Go to the note, or the line in it, that this panel line stands for."
  (interactive)
  (vault-panel--open (or (get-text-property (pos-bol) 'vault-item)
                         (user-error "Nothing to visit on this line"))
                     vault-local-root))

(defun vault-panel-peek ()
  "Show this panel line's note in the other window and stay in the panel."
  (interactive)
  (let ((panel (selected-window)))
    (vault-panel-visit)
    (select-window panel)))

(defun vault-panel-link-mention ()
  "Turn the unlinked mention on this panel line into a link."
  (interactive)
  (let* ((item (get-text-property (pos-bol) 'vault-item))
         (note (or (plist-get item :mention)
                   (user-error "This line is not an unlinked mention"))))
    (if (vault-link-mention (plist-get item :path) (plist-get item :line) note)
        (progn (setq vault-panel--shown nil)
               (vault-panel-refresh)
               (message "Linked"))
      (message "The mention is no longer on that line"))))

(provide 'vault-ui)
;;; vault-ui.el ends here
