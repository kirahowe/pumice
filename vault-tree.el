;;; vault-tree.el --- A folder tree of the vault -*- lexical-binding: t; -*-

;;; Commentary:

;; `vault-tree' shows the vault's folders and notes in a side window on the
;; left, like Obsidian's file explorer.  Folders fold, the tree follows the
;; note being edited, and notes can be opened, started and renamed from it.

;;; Code:

(require 'vault)
(require 'vault-commands)
(require 'vault-refactor)
(require 'vault-ui)

(defconst vault-tree-buffer "*vault-tree*" "Name of the tree buffer.")

(defcustom vault-tree-width 34
  "Width of the folder tree in columns."
  :type 'integer :group 'vault)

(defface vault-tree-folder '((t :inherit font-lock-function-name-face))
  "A folder in the tree." :group 'vault)
(defface vault-tree-current '((t :inherit (bold vault-link)))
  "The note being edited, as shown in the tree." :group 'vault)

(defvar-local vault-tree--expanded nil
  "Hash table whose keys are the absolute paths of the unfolded folders.")
(defvar-local vault-tree--current nil
  "Path of the note the tree marks as the one being edited.")
(defvar-local vault-tree--drawn nil
  "What the tree last drew: (ROOT . TICK).")
(defvar-local vault-tree--sort 'name
  "Order within a folder: `name', or `modified' for newest first.")
(defvar vault-tree--timer nil)

(defvar-keymap vault-tree-mode-map
  :doc "Keys in the folder tree."
  "RET" #'vault-tree-visit
  "o" #'vault-tree-peek
  "TAB" #'vault-tree-toggle
  "s" #'vault-tree-sort
  "a" #'vault-tree-new-note
  "r" #'vault-tree-rename
  "g" #'vault-tree-refresh
  "q" #'vault-tree-quit)

(define-derived-mode vault-tree-mode vault-side-mode "Vault-Tree"
  "The folders and notes of a vault."
  (setq vault-tree--expanded (make-hash-table :test 'equal))
  (hl-line-mode 1))

;;; The tree

(defun vault-tree--parent (rel)
  "Return the folder holding REL, or \"\" at the top of the vault."
  (directory-file-name (or (file-name-directory rel) "")))

(defun vault-tree--model (vault)
  "Return (CHILDREN . STATS), two hash tables describing VAULT's folders.
Both are keyed by folder path relative to the root, \"\" for the root
itself.  CHILDREN gives a folder's entries, each (dir REL), (note NOTE) or
(file REL).  STATS gives (COUNT . MTIME): how many notes are anywhere below
the folder, and when the newest of them changed."
  (let ((children (make-hash-table :test 'equal))
        (stats (make-hash-table :test 'equal)))
    (cl-flet ((add (entry rel mtime)
                (let ((dir (vault-tree--parent rel)))
                  (push entry (gethash dir children))
                  (while (not (string-empty-p dir))
                    (let ((stat (or (gethash dir stats)
                                    (progn
                                      (push (list 'dir dir)
                                            (gethash (vault-tree--parent dir)
                                                     children))
                                      (puthash dir (list 0) stats)))))
                      (when mtime
                        (cl-incf (car stat))
                        (when (or (null (cdr stat))
                                  (time-less-p (cdr stat) mtime))
                          (setcdr stat mtime))))
                    (setq dir (vault-tree--parent dir))))))
      (maphash (lambda (_ note)
                 (add (list 'note note) (vault-note-rel note)
                      (vault-note-mtime note)))
               (vault--notes vault))
      (dolist (rel (vault--files vault))
        (add (list 'file rel) rel nil)))
    (cons children stats)))

(defun vault-tree--sorted (entries stats)
  "Return ENTRIES in display order: folders, then notes, then other files.
Within each kind the order follows `vault-tree--sort'.  STATS is the
folder table from `vault-tree--model'."
  (let ((rank (lambda (entry) (pcase (car entry) ('dir 0) ('note 1) (_ 2))))
        (name (lambda (entry)
                (downcase (pcase entry
                            (`(note ,note) (vault-note-name note))
                            (`(,_ ,rel) (file-name-nondirectory rel))))))
        (mtime (lambda (entry)
                 (pcase entry
                   (`(note ,note) (vault-note-mtime note))
                   (`(dir ,rel) (cdr (gethash rel stats)))))))
    (sort (copy-sequence entries)
          (lambda (a b)
            (let ((ra (funcall rank a)) (rb (funcall rank b))
                  (ma (funcall mtime a)) (mb (funcall mtime b)))
              (cond ((/= ra rb) (< ra rb))
                    ;; A folder with no notes in it has no time: it goes last.
                    ((and (eq vault-tree--sort 'modified) (or ma mb)
                          (not (and ma mb (time-equal-p ma mb))))
                     (and ma (or (null mb) (time-less-p mb ma))))
                    ;; Version order, so that Week 2 comes before Week 10.
                    (t (string-version-lessp (funcall name a)
                                             (funcall name b)))))))))

(defun vault-tree--insert (dir depth model root)
  "Insert the entries of folder DIR, indented to DEPTH.
MODEL is from `vault-tree--model' and ROOT is the vault root.  Each line
carries its absolute path as `vault-path', and folders `vault-dir' too."
  (pcase-let ((`(,children . ,stats) model)
              (indent (make-string (* 2 depth) ?\s)))
    (dolist (entry (vault-tree--sorted (gethash dir children) stats))
      (let ((start (point)))
        (pcase entry
          (`(dir ,rel)
           (let* ((path (expand-file-name rel root))
                  (open (gethash path vault-tree--expanded))
                  (count (car (gethash rel stats))))
             (insert indent
                     (propertize (concat (if open "▾ " "▸ ")
                                         (file-name-nondirectory rel))
                                 'face 'vault-tree-folder)
                     (if (zerop count) ""
                       (propertize (format "  %d" count) 'face 'shadow))
                     "\n")
             (add-text-properties start (point)
                                  (list 'vault-path path 'vault-dir t))
             (when open (vault-tree--insert rel (1+ depth) model root))))
          (`(note ,note)
           (let ((path (vault-note-path note)))
             (insert indent "  "
                     (if (equal path vault-tree--current)
                         (propertize (vault-note-name note)
                                     'face 'vault-tree-current)
                       (vault-note-name note))
                     "\n")
             (add-text-properties start (point) (list 'vault-path path))))
          (`(file ,rel)
           (insert indent "  "
                   (propertize (file-name-nondirectory rel) 'face 'shadow)
                   "\n")
           (add-text-properties
            start (point) (list 'vault-path (expand-file-name rel root)))))))))

(defun vault-tree--goto (path)
  "Move to the line for PATH.  Return nil, without moving, if it has none."
  (let ((pos (point-min)) found)
    (while (and pos (not found))
      (if (equal (get-text-property pos 'vault-path) path)
          (setq found pos)
        (setq pos (next-single-property-change pos 'vault-path))))
    (when found (goto-char found))))

(defun vault-tree--render (vault)
  "Draw VAULT's tree in the current buffer, keeping point on its entry."
  ;; While the tree's window is not the selected one, the window's point
  ;; is where the cursor shows, and the buffer's own point can lag behind.
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (goto-char (window-point window)))
  (let ((inhibit-read-only t)
        (root (vault--root vault))
        (here (get-text-property (pos-bol) 'vault-path))
        (line (line-number-at-pos)))
    (erase-buffer)
    (setq vault-local-root root
          vault-tree--drawn (cons root (vault--tick vault))
          header-line-format
          (string-replace
           "%" "%%"
           (format " %s  %d notes%s"
                   (file-name-nondirectory (directory-file-name root))
                   (hash-table-count (vault--notes vault))
                   (if (eq vault-tree--sort 'modified) ", by date" ""))))
    (vault-tree--insert "" 0 (vault-tree--model vault) root)
    (set-buffer-modified-p nil)
    (unless (and here (vault-tree--goto here))
      (goto-char (point-min))
      (forward-line (1- line)))
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (set-window-point window (point)))))

(defun vault-tree--reveal (path)
  "Unfold every folder between the vault root and PATH."
  (let ((dir (file-name-directory path)))
    (while (and (string-prefix-p vault-local-root dir)
                (not (equal dir vault-local-root)))
      (puthash (directory-file-name dir) t vault-tree--expanded)
      (setq dir (file-name-directory (directory-file-name dir))))))

(defun vault-tree--sync (&optional force)
  "Bring the tree up to date with the selected window and the index.
When the selected window shows a different note than before, unfold the
way to it and move there.  With FORCE, redraw whatever happened."
  (let* ((tree (get-buffer vault-tree-buffer))
         (window (and tree (get-buffer-window tree t))))
    (if (not window)
        (when vault-tree--timer
          (cancel-timer vault-tree--timer)
          (setq vault-tree--timer nil))
      (let* ((path (buffer-file-name (window-buffer (selected-window))))
             (root (and path (vault-root-for path)))
             (vault (vault-get
                     (or root (buffer-local-value 'vault-local-root tree)))))
        (with-current-buffer tree
          (let ((moved (and root (not (equal path vault-tree--current)))))
            (when moved
              (setq vault-tree--current path
                    vault-local-root root)
              (vault-tree--reveal path))
            (when (or force moved
                      (not (equal vault-tree--drawn
                                  (cons (vault--root vault)
                                        (vault--tick vault)))))
              (vault-tree--render vault)
              (when (and moved (vault-tree--goto path))
                (set-window-point window (point))))))))))

;;; Commands

;;;###autoload
(defun vault-tree ()
  "Show the vault's folder tree and move to it.
From inside the tree, hide it."
  (interactive)
  (let ((window (get-buffer-window vault-tree-buffer)))
    (cond
     ((and window (eq window (selected-window))) (delete-window window))
     (window (select-window window))
     (t
      (let ((root (vault--root (vault-current))))
        (with-current-buffer (get-buffer-create vault-tree-buffer)
          (unless (derived-mode-p 'vault-tree-mode) (vault-tree-mode))
          (setq vault-local-root root)
          (vault--show-side-window (current-buffer) 'left vault-tree-width)))
      (unless vault-tree--timer
        (setq vault-tree--timer
              (run-with-idle-timer 0.2 t #'vault-tree--sync)))
      (vault-tree--sync t)
      (select-window (get-buffer-window vault-tree-buffer))))))

(defun vault-tree-quit ()
  "Hide the folder tree."
  (interactive)
  (when-let* ((window (get-buffer-window vault-tree-buffer)))
    (delete-window window)))

(defun vault-tree--path ()
  "Return the path of the entry on this line."
  (or (get-text-property (pos-bol) 'vault-path)
      (user-error "Nothing on this line")))

(defun vault-tree--dir-p ()
  "Non-nil if this line is a folder."
  (get-text-property (pos-bol) 'vault-dir))

(defun vault-tree--redraw ()
  "Draw the tree again from the index as it stands."
  (vault-tree--render (vault-get vault-local-root t)))

(defun vault-tree--set-fold (path open)
  "Unfold the folder at PATH if OPEN is non-nil, else fold it, and redraw."
  (if open
      (puthash path t vault-tree--expanded)
    (remhash path vault-tree--expanded))
  (vault-tree--redraw))

(defun vault-tree-toggle ()
  "Fold or unfold the folder on this line."
  (interactive)
  (let ((path (vault-tree--path)))
    (unless (vault-tree--dir-p) (user-error "Not a folder"))
    (vault-tree--set-fold path (not (gethash path vault-tree--expanded)))))

(defun vault-tree-visit ()
  "Open the note on this line, or fold or unfold the folder on it."
  (interactive)
  (let ((path (vault-tree--path)))
    (if (vault-tree--dir-p)
        (vault-tree-toggle)
      (select-window (or (get-mru-window nil nil t) (next-window)))
      (vault--visit path))))

(defun vault-tree-peek ()
  "Show the note on this line in the other window and stay in the tree."
  (interactive)
  (let ((tree (selected-window)))
    (vault-tree-visit)
    (vault-tree--sync)
    (select-window tree)))

(defun vault-tree-expand ()
  "Go one step in: unfold a folder, enter an unfolded one, or open a note."
  (interactive)
  (let ((path (vault-tree--path)))
    (cond ((not (vault-tree--dir-p)) (vault-tree-visit))
          ((gethash path vault-tree--expanded) (forward-line 1))
          (t (vault-tree--set-fold path t)))))

(defun vault-tree-collapse ()
  "Go one step out: fold an unfolded folder, else move to the parent folder."
  (interactive)
  (let ((path (vault-tree--path)))
    (if (and (vault-tree--dir-p) (gethash path vault-tree--expanded))
        (vault-tree--set-fold path nil)
      (vault-tree--goto (directory-file-name (file-name-directory path))))))

(defun vault-tree-collapse-all ()
  "Fold every folder."
  (interactive)
  (let* ((path (get-text-property (pos-bol) 'vault-path))
         (top (and path (car (split-string
                              (file-relative-name path vault-local-root)
                              "/")))))
    (clrhash vault-tree--expanded)
    (vault-tree--redraw)
    ;; The entry point was on may be folded away; stay with its top folder.
    (when top (vault-tree--goto (expand-file-name top vault-local-root)))))

(defun vault-tree-expand-all ()
  "Unfold every folder."
  (interactive)
  (let ((vault (vault-get vault-local-root t)))
    (maphash (lambda (rel _)
               (puthash (expand-file-name rel vault-local-root) t
                        vault-tree--expanded))
             (cdr (vault-tree--model vault)))
    (vault-tree--render vault)))

(defun vault-tree-sort ()
  "Switch between sorting by name and newest first."
  (interactive)
  (setq vault-tree--sort (if (eq vault-tree--sort 'name) 'modified 'name))
  (vault-tree--redraw)
  (message "Sorted by %s" (if (eq vault-tree--sort 'name)
                              "name" "last change, newest first")))

(defun vault-tree-refresh ()
  "Read the vault from disk again and redraw."
  (interactive)
  (vault-tree--render (vault-refresh (vault-get vault-local-root t) t)))

(defun vault-tree--folder ()
  "Return the folder this line is in: itself if it is one, else its parent.
On an empty line that is the vault root."
  (let ((path (get-text-property (pos-bol) 'vault-path)))
    (cond ((null path) (directory-file-name vault-local-root))
          ((vault-tree--dir-p) path)
          (t (directory-file-name (file-name-directory path))))))

(defun vault-tree-new-note (dir name)
  "Start a note called NAME in the folder DIR.
Interactively DIR is the folder on this line, or the one holding the note
on it.  Like every new note it is an unsaved buffer until first saved."
  (interactive
   (let ((dir (vault-tree--folder)))
     (list dir (read-string
                (format "New note in %s/: "
                        (file-name-nondirectory
                         (directory-file-name
                          (if (equal (file-name-as-directory dir)
                                     vault-local-root)
                              vault-local-root
                            dir))))))))
  (let ((name (string-remove-suffix ".md" (string-trim name))))
    (when (string-empty-p name) (user-error "A note needs a name"))
    (let ((path (concat (expand-file-name name dir) ".md")))
      (select-window (or (get-mru-window nil nil t) (next-window)))
      (vault--visit path)
      (unless (file-exists-p path)
        (message "New note: %s (save to create it)" name)))))

(defun vault-tree-rename (path new-rel)
  "Rename or move the note at PATH to NEW-REL, updating links to it.
NEW-REL is relative to the vault root, so editing the folder part moves
the note.  Interactively PATH is the note on this line."
  (interactive
   (let* ((path (vault-tree--path))
          (note (or (vault-note-at (vault-get vault-local-root) path)
                    (user-error "Only notes can be renamed from the tree"))))
     (list path (read-string "Rename to: " (vault-note-rel note)))))
  (let* ((vault (vault-get vault-local-root))
         (note (or (vault-note-at vault path)
                   (user-error "Only notes can be renamed from the tree")))
         (new-rel (string-remove-suffix ".md" (string-trim new-rel)))
         (new-path (concat (expand-file-name new-rel vault-local-root) ".md")))
    (if (equal new-rel (vault-note-rel note))
        (message "Name unchanged")
      (let ((count (vault-rename-note vault note new-rel)))
        (when (equal vault-tree--current path)
          (setq vault-tree--current new-path))
        (vault-tree--reveal new-path)
        (vault-tree--redraw)
        (vault-tree--goto new-path)
        (message "Renamed to %s, %d link%s updated"
                 new-rel count (if (= count 1) "" "s"))))))

(provide 'vault-tree)
;;; vault-tree.el ends here
