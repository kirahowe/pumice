;;; pumice-tree.el --- A folder tree of the vault -*- lexical-binding: t; -*-

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

;; `pumice-tree' shows the vault's folders and notes in a side window on the
;; left, like Obsidian's file explorer.  Folders fold, the tree follows the
;; note being edited, and notes can be opened, started and renamed from it.

;;; Code:

(require 'pumice-core)
(require 'pumice-commands)
(require 'pumice-refactor)
(require 'pumice-ui)

(defconst pumice-tree-buffer "*pumice-tree*" "Name of the tree buffer.")

(defcustom pumice-tree-width 34
  "Width of the folder tree in columns."
  :type 'integer :group 'pumice)

(defface pumice-tree-folder '((t :inherit font-lock-function-name-face))
  "A folder in the tree." :group 'pumice)
(defface pumice-tree-current '((t :inherit (bold pumice-link)))
  "The note being edited, as shown in the tree." :group 'pumice)

(defvar-local pumice-tree--expanded nil
  "Hash table whose keys are the absolute paths of the unfolded folders.")
(defvar-local pumice-tree--current nil
  "Path of the note the tree marks as the one being edited.")
(defvar-local pumice-tree--drawn nil
  "What the tree last drew: (ROOT . TICK).")
(defvar-local pumice-tree--sort 'name
  "Order within a folder: `name', or `modified' for newest first.")
(defvar pumice-tree--timer nil)

(defvar-keymap pumice-tree-mode-map
  :doc "Keys in the folder tree."
  "RET" #'pumice-tree-visit
  "o" #'pumice-tree-peek
  "TAB" #'pumice-tree-toggle
  "<right>" #'pumice-tree-expand
  "<left>" #'pumice-tree-collapse
  "E" #'pumice-tree-expand-all
  "C" #'pumice-tree-collapse-all
  "n" #'next-line
  "p" #'previous-line
  "s" #'pumice-tree-sort
  "a" #'pumice-tree-new-note
  "r" #'pumice-tree-rename
  "g" #'pumice-tree-refresh
  "q" #'pumice-tree-quit)

(define-derived-mode pumice-tree-mode pumice-side-mode "Pumice-Tree"
  "The folders and notes of a vault."
  (setq pumice-tree--expanded (make-hash-table :test 'equal))
  (hl-line-mode 1))

;;; The tree

(defun pumice-tree--parent (rel)
  "Return the folder holding REL, or \"\" at the top of the vault."
  (directory-file-name (or (file-name-directory rel) "")))

(defun pumice-tree--model (vault)
  "Return (CHILDREN . STATS), two hash tables describing VAULT's folders.
Both are keyed by folder path relative to the root, \"\" for the root
itself.  CHILDREN gives a folder's entries, each (dir REL), (note NOTE)
or (file REL).  STATS gives (COUNT . MTIME): how many notes are anywhere
below the folder, and when the newest of them changed."
  (let ((children (make-hash-table :test 'equal))
        (stats (make-hash-table :test 'equal)))
    (cl-flet ((add (entry rel mtime)
                (let ((dir (pumice-tree--parent rel)))
                  (push entry (gethash dir children))
                  (while (not (string-empty-p dir))
                    (let ((stat (or (gethash dir stats)
                                    (progn
                                      (push (list 'dir dir)
                                            (gethash (pumice-tree--parent dir)
                                                     children))
                                      (puthash dir (list 0) stats)))))
                      (when mtime
                        (cl-incf (car stat))
                        (when (or (null (cdr stat))
                                  (time-less-p (cdr stat) mtime))
                          (setcdr stat mtime))))
                    (setq dir (pumice-tree--parent dir))))))
      (maphash (lambda (_ note)
                 (add (list 'note note) (pumice-note-rel note)
                      (pumice-note-mtime note)))
               (pumice--notes vault))
      (dolist (rel (pumice--files vault))
        (add (list 'file rel) rel nil)))
    (cons children stats)))

(defun pumice-tree--sorted (entries stats)
  "Return ENTRIES in display order: folders, then notes, then other files.
Within each kind the order follows `pumice-tree--sort'.  STATS is the
folder table from `pumice-tree--model'."
  (let ((rank (lambda (entry) (pcase (car entry) ('dir 0) ('note 1) (_ 2))))
        (name (lambda (entry)
                (downcase (pcase entry
                            (`(note ,note) (pumice-note-name note))
                            (`(,_ ,rel) (file-name-nondirectory rel))))))
        (mtime (lambda (entry)
                 (pcase entry
                   (`(note ,note) (pumice-note-mtime note))
                   (`(dir ,rel) (cdr (gethash rel stats)))))))
    (sort (copy-sequence entries)
          (lambda (a b)
            (let ((ra (funcall rank a)) (rb (funcall rank b))
                  (ma (funcall mtime a)) (mb (funcall mtime b)))
              (cond ((/= ra rb) (< ra rb))
                    ;; A folder with no notes in it has no time: it goes last.
                    ((and (eq pumice-tree--sort 'modified) (or ma mb)
                          (not (and ma mb (time-equal-p ma mb))))
                     (and ma (or (null mb) (time-less-p mb ma))))
                    ;; Version order, so that Week 2 comes before Week 10.
                    (t (string-version-lessp (funcall name a)
                                             (funcall name b)))))))))

(defun pumice-tree--insert (dir depth model root)
  "Insert the entries of folder DIR, indented to DEPTH.
MODEL is from `pumice-tree--model' and ROOT is the vault root.  Each line
carries its absolute path as `pumice-path', and folders `pumice-dir' too."
  (pcase-let ((`(,children . ,stats) model)
              (indent (make-string (* 2 depth) ?\s)))
    (dolist (entry (pumice-tree--sorted (gethash dir children) stats))
      (let ((start (point)))
        (pcase entry
          (`(dir ,rel)
           (let* ((path (expand-file-name rel root))
                  (open (gethash path pumice-tree--expanded))
                  (count (car (gethash rel stats))))
             (insert indent
                     (propertize (concat (if open "▾ " "▸ ")
                                         (file-name-nondirectory rel))
                                 'face 'pumice-tree-folder)
                     (if (zerop count) ""
                       (propertize (format "  %d" count) 'face 'shadow))
                     "\n")
             (add-text-properties start (point)
                                  (list 'pumice-path path 'pumice-dir t))
             (when open (pumice-tree--insert rel (1+ depth) model root))))
          (`(note ,note)
           (let ((path (pumice-note-path note)))
             (insert indent "  "
                     (if (equal path pumice-tree--current)
                         (propertize (pumice-note-name note)
                                     'face 'pumice-tree-current)
                       (pumice-note-name note))
                     "\n")
             (add-text-properties start (point) (list 'pumice-path path))))
          (`(file ,rel)
           (insert indent "  "
                   (propertize (file-name-nondirectory rel) 'face 'shadow)
                   "\n")
           (add-text-properties
            start (point) (list 'pumice-path (expand-file-name rel root)))))))))

(defun pumice-tree--goto (path)
  "Move to the line for PATH.  Return nil, without moving, if it has none."
  (let ((pos (point-min)) found)
    (while (and pos (not found))
      (if (equal (get-text-property pos 'pumice-path) path)
          (setq found pos)
        (setq pos (next-single-property-change pos 'pumice-path))))
    (when found (goto-char found))))

(defun pumice-tree--render (vault)
  "Draw VAULT's tree in the current buffer, keeping point on its entry."
  ;; While the tree's window is not the selected one, the window's point
  ;; is where the cursor shows, and the buffer's own point can lag behind.
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (goto-char (window-point window)))
  (let ((inhibit-read-only t)
        (root (pumice--root vault))
        (here (get-text-property (pos-bol) 'pumice-path))
        (line (line-number-at-pos)))
    (erase-buffer)
    (setq pumice-local-root root
          pumice-tree--drawn (cons root (pumice--tick vault))
          header-line-format
          (string-replace
           "%" "%%"
           (format " %s  %d notes%s"
                   (file-name-nondirectory (directory-file-name root))
                   (hash-table-count (pumice--notes vault))
                   (if (eq pumice-tree--sort 'modified) ", by date" ""))))
    (pumice-tree--insert "" 0 (pumice-tree--model vault) root)
    (set-buffer-modified-p nil)
    (unless (and here (pumice-tree--goto here))
      (goto-char (point-min))
      (forward-line (1- line)))
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (set-window-point window (point)))))

(defun pumice-tree--reveal (path)
  "Unfold every folder between the vault root and PATH."
  (let ((dir (file-name-directory path)))
    (while (and (string-prefix-p pumice-local-root dir)
                (not (equal dir pumice-local-root)))
      (puthash (directory-file-name dir) t pumice-tree--expanded)
      (setq dir (file-name-directory (directory-file-name dir))))))

(defun pumice-tree--sync (&optional force)
  "Bring the tree up to date with the note being read and the index.
That note is the selected window's, or the main window's while the tree or
the panel is selected.  When it is a different note than before, unfold
the way to it and move there.  With FORCE, redraw whatever happened."
  (let* ((tree (get-buffer pumice-tree-buffer))
         (window (and tree (get-buffer-window tree t))))
    (if (not window)
        (when pumice-tree--timer
          (cancel-timer pumice-tree--timer)
          (setq pumice-tree--timer nil))
      (let* ((path (buffer-file-name (window-buffer (pumice--main-window))))
             (root (and path (pumice-root-for path)))
             (vault (pumice-vault-at
                     (or root (buffer-local-value 'pumice-local-root tree)))))
        (with-current-buffer tree
          (let ((moved (and root (not (equal path pumice-tree--current)))))
            (when moved
              (setq pumice-tree--current path
                    pumice-local-root root)
              (pumice-tree--reveal path))
            (when (or force moved
                      (not (equal pumice-tree--drawn
                                  (cons (pumice--root vault)
                                        (pumice--tick vault)))))
              (pumice-tree--render vault)
              (when (and moved (pumice-tree--goto path))
                (set-window-point window (point))))))))))

;;; Commands

;;;###autoload
(defun pumice-tree ()
  "Show the vault's folder tree and move to it.
From inside the tree, hide it."
  (interactive)
  (let ((window (get-buffer-window pumice-tree-buffer)))
    (cond
     ((and window (eq window (selected-window))) (delete-window window))
     (window (select-window window))
     (t
      (let ((root (pumice--root (pumice-current-vault))))
        (with-current-buffer (get-buffer-create pumice-tree-buffer)
          (unless (derived-mode-p 'pumice-tree-mode) (pumice-tree-mode))
          (setq pumice-local-root root)
          (pumice--show-side-window (current-buffer) 'left pumice-tree-width)))
      (unless pumice-tree--timer
        (setq pumice-tree--timer
              (run-with-idle-timer 0.2 t #'pumice-tree--sync)))
      (pumice-tree--sync t)
      (select-window (get-buffer-window pumice-tree-buffer))))))

(defun pumice-tree-quit ()
  "Hide the folder tree."
  (interactive)
  (when-let* ((window (get-buffer-window pumice-tree-buffer)))
    (delete-window window)))

(defun pumice-tree--path ()
  "Return the path of the entry on this line."
  (or (get-text-property (pos-bol) 'pumice-path)
      (user-error "Nothing on this line")))

(defun pumice-tree--dir-p ()
  "Non-nil if this line is a folder."
  (get-text-property (pos-bol) 'pumice-dir))

(defun pumice-tree--redraw ()
  "Draw the tree again from the index as it stands."
  (pumice-tree--render (pumice-vault-at pumice-local-root t)))

(defun pumice-tree--set-fold (path open)
  "Unfold the folder at PATH if OPEN is non-nil, else fold it, and redraw."
  (if open
      (puthash path t pumice-tree--expanded)
    (remhash path pumice-tree--expanded))
  (pumice-tree--redraw))

(defun pumice-tree-toggle ()
  "Fold or unfold the folder on this line."
  (interactive)
  (let ((path (pumice-tree--path)))
    (unless (pumice-tree--dir-p) (user-error "Not a folder"))
    (pumice-tree--set-fold path (not (gethash path pumice-tree--expanded)))))

(defun pumice-tree-visit ()
  "Open the note on this line, or fold or unfold the folder on it."
  (interactive)
  (let ((path (pumice-tree--path)))
    (if (pumice-tree--dir-p)
        (pumice-tree-toggle)
      (select-window (or (get-mru-window nil nil t) (next-window)))
      (pumice--visit path))))

(defun pumice-tree-peek ()
  "Show the note on this line in the other window and stay in the tree."
  (interactive)
  (let ((tree (selected-window)))
    (pumice-tree-visit)
    (pumice-tree--sync)
    (select-window tree)))

(defun pumice-tree-expand ()
  "Go one step in: unfold a folder, enter an unfolded one, or open a note."
  (interactive)
  (let ((path (pumice-tree--path)))
    (cond ((not (pumice-tree--dir-p)) (pumice-tree-visit))
          ((gethash path pumice-tree--expanded) (forward-line 1))
          (t (pumice-tree--set-fold path t)))))

(defun pumice-tree-collapse ()
  "Go one step out: fold an unfolded folder, else move to the parent folder."
  (interactive)
  (let ((path (pumice-tree--path)))
    (if (and (pumice-tree--dir-p) (gethash path pumice-tree--expanded))
        (pumice-tree--set-fold path nil)
      (pumice-tree--goto (directory-file-name (file-name-directory path))))))

(defun pumice-tree-collapse-all ()
  "Fold every folder."
  (interactive)
  (let* ((path (get-text-property (pos-bol) 'pumice-path))
         (top (and path (car (split-string
                              (file-relative-name path pumice-local-root)
                              "/")))))
    (clrhash pumice-tree--expanded)
    (pumice-tree--redraw)
    ;; The entry point was on may be folded away; stay with its top folder.
    (when top (pumice-tree--goto (expand-file-name top pumice-local-root)))))

(defun pumice-tree-expand-all ()
  "Unfold every folder."
  (interactive)
  (let ((vault (pumice-vault-at pumice-local-root t)))
    (maphash (lambda (rel _)
               (puthash (expand-file-name rel pumice-local-root) t
                        pumice-tree--expanded))
             (cdr (pumice-tree--model vault)))
    (pumice-tree--render vault)))

(defun pumice-tree-sort ()
  "Switch between sorting by name and newest first."
  (interactive)
  (setq pumice-tree--sort (if (eq pumice-tree--sort 'name) 'modified 'name))
  (pumice-tree--redraw)
  (message "Sorted by %s" (if (eq pumice-tree--sort 'name)
                              "name" "last change, newest first")))

(defun pumice-tree-refresh ()
  "Read the vault from disk again and redraw."
  (interactive)
  (pumice-tree--render (pumice-refresh (pumice-vault-at pumice-local-root t) t)))

(defun pumice-tree--folder ()
  "Return the folder this line is in: itself if it is one, else its parent.
On an empty line that is the vault root."
  (let ((path (get-text-property (pos-bol) 'pumice-path)))
    (cond ((null path) (directory-file-name pumice-local-root))
          ((pumice-tree--dir-p) path)
          (t (directory-file-name (file-name-directory path))))))

(defun pumice-tree-new-note (dir name)
  "Start a note called NAME in the folder DIR.
Interactively DIR is the folder on this line, or the one holding the note
on it.  Like every new note it is an unsaved buffer until first saved."
  (interactive
   (let ((dir (pumice-tree--folder)))
     (list dir (read-string
                (format "New note in %s/: "
                        (file-name-nondirectory
                         (directory-file-name
                          (if (equal (file-name-as-directory dir)
                                     pumice-local-root)
                              pumice-local-root
                            dir))))))))
  (let ((name (string-remove-suffix ".md" (string-trim name))))
    (when (string-empty-p name) (user-error "A note needs a name"))
    (let ((path (concat (expand-file-name name dir) ".md")))
      (select-window (or (get-mru-window nil nil t) (next-window)))
      (pumice--visit path)
      (unless (file-exists-p path)
        (message "New note: %s (save to create it)" name)))))

(defun pumice-tree-rename (path new-rel)
  "Rename or move the note at PATH to NEW-REL, updating links to it.
NEW-REL is relative to the vault root, so editing the folder part moves
the note.  Interactively PATH is the note on this line."
  (interactive
   (let* ((path (pumice-tree--path))
          (note (or (pumice-note-at (pumice-vault-at pumice-local-root) path)
                    (user-error "Only notes can be renamed from the tree"))))
     (list path (read-string "Rename to: " (pumice-note-rel note)))))
  (let* ((vault (pumice-vault-at pumice-local-root))
         (note (or (pumice-note-at vault path)
                   (user-error "Only notes can be renamed from the tree")))
         (new-rel (string-remove-suffix ".md" (string-trim new-rel)))
         (new-path (concat (expand-file-name new-rel pumice-local-root) ".md")))
    (if (equal new-rel (pumice-note-rel note))
        (message "Name unchanged")
      (let ((count (pumice-rename-note vault note new-rel)))
        (when (equal pumice-tree--current path)
          (setq pumice-tree--current new-path))
        (pumice-tree--reveal new-path)
        (pumice-tree--redraw)
        (pumice-tree--goto new-path)
        (message "Renamed to %s, %d link%s updated"
                 new-rel count (if (= count 1) "" "s"))))))

(provide 'pumice-tree)
;;; pumice-tree.el ends here
